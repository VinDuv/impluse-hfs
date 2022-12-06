//
//  ImpHFSExtractor.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-02.
//

#import "ImpHFSExtractor.h"

#import "ImpHFSVolume.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpDehydratedItem.h"

@implementation ImpHFSExtractor

- (void) deliverProgressUpdate:(float)progress
	operationDescription:(NSString *_Nonnull)operationDescription
{
	if (self.extractionProgressUpdateBlock != nil) {
		self.extractionProgressUpdateBlock(progress, operationDescription);
	}
}

- (bool) isHFSPath:(NSString *_Nonnull const) maybePath {
	return [maybePath containsString:@":"];
}

///Parse an HFS-style (colon-separated) path string and return the components in order as an array of strings. TN1041 gives the rules for parsing pathnames. If the path is relative (begins with a colon), the returned array will begin with an empty string. (In our case, it probably makes the most sense to consider the path relative to the volume.) Returns nil if the pathname is invalid (e.g., too many consecutive colons).
- (NSArray <NSString *> *_Nullable const) parseHFSPath:(NSString *_Nonnull const)hfsPathString {
	//As a rough heuristic, assume filenames average 8 characters long and preallocate that much space.
	NSMutableArray *_Nonnull const path = [NSMutableArray arrayWithCapacity:hfsPathString.length / 8];

	@autoreleasepool {
		//Ignore a single trailing colon (by pruning it off before we feed the string to the scanner).
		NSString *_Nonnull const trimmedString = [hfsPathString hasSuffix:@":"] ? [hfsPathString substringToIndex:hfsPathString.length - 1] : hfsPathString;

		NSScanner *_Nonnull const scanner = [NSScanner scannerWithString:trimmedString];
		//Don't skip any characters—we want 'em all.
		scanner.charactersToBeSkipped = [NSCharacterSet characterSetWithRange:(NSRange){ 0, 0 }];

		bool const isRelativePath = [scanner scanString:@":" intoString:NULL];
		if (isRelativePath)
			[path addObject:@""];

		while (! scanner.isAtEnd) {
			NSString *_Nullable filename = nil;
			bool const gotAFilename = [scanner scanUpToString:@":" intoString:&filename];
			if (gotAFilename) {
				[path addObject:filename];
			} else {
				//Empty string. If we have any path components, pop one off—consecutive colons is the equivalent of “..” in POSIX paths. If we've run out of path components, this pathname is invalid.
				if (path.count > 0) {
					[path removeLastObject];
				} else {
					return nil;
				}
			}
		}
	}

	return path;
}

- (NSString *_Nonnull const) quarryName {
	return [self parseHFSPath:self.quarryNameOrPath].lastObject;
}

///Return whether a quarry path from parseHFSPath: matches a given path for a catalog item. Returns true for any volume name if the first item in the quarry path is the empty string (indicating a relative path, which we interpret as relative to the volume root).
- (bool) isQuarryPath:(NSArray <NSString *> *_Nonnull const)quarryPath isEqualToCatalogPath:(NSArray <NSString *> *_Nonnull const)catalogPath {
	if (quarryPath.count != catalogPath.count) {
		return false;
	}
	NSEnumerator <NSString *> *_Nonnull const quarryPathEnum = [quarryPath objectEnumerator];
	NSEnumerator <NSString *> *_Nonnull const catalogPathEnum = [catalogPath objectEnumerator];

	NSString *_Nonnull const quarryVolumeName = [quarryPathEnum nextObject];
	NSString *_Nonnull const catalogVolumeName = [catalogPathEnum nextObject];
	if (quarryVolumeName == catalogVolumeName) {
		//They're both nil. We're comparing two empty paths. Yup, they're equal!
		return true;
	}

	if (quarryVolumeName.length == 0 || [quarryVolumeName isEqualToString:catalogVolumeName]) {
		//Step through both arrays in parallel, comparing pairs of items as we go. Bail at the first non-equal pair.
		NSString *_Nullable quarryItemName = [quarryPathEnum nextObject], *_Nullable catalogItemName = [catalogPathEnum nextObject];
		while (quarryItemName != nil && catalogItemName != nil && [quarryItemName isEqualToString:catalogItemName]) {
			quarryItemName = [quarryPathEnum nextObject];
			catalogItemName = [catalogPathEnum nextObject];
		}

		//If we have indeed made it to the end of both arrays, then all items were equal.
		if (quarryItemName == nil && catalogItemName == nil) {
			return true;
		}
	}
	return false;
}

- (bool)performExtractionOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	__block bool rehydrated = false;

	int const readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}

	[self deliverProgressUpdate:0.0 operationDescription:@"Reading HFS volume structures"];

	ImpHFSVolume *_Nonnull const srcVol = [[ImpHFSVolume alloc] initWithFileDescriptor:readFD];
	if (! [srcVol loadAndReturnError:outError])
		return false;

	struct HFSMasterDirectoryBlock mdb;
	[srcVol getVolumeHeader:&mdb];
	[self deliverProgressUpdate:0.01 operationDescription:[NSString stringWithFormat:@"Found HFS volume named “%@”", srcVol.volumeName]];
	[self deliverProgressUpdate:0.01 operationDescription:[NSString stringWithFormat:@"Block size is %lu bytes; volume has %lu blocks in use, %lu free", srcVol.numberOfBytesPerBlock, srcVol.numberOfBlocksUsed, srcVol.numberOfBlocksFree]];
	NSByteCountFormatter *_Nonnull const bcf = [NSByteCountFormatter new];
	[self deliverProgressUpdate:0.01 operationDescription:[NSString stringWithFormat:@"Volume size is %@; %@ in use, %@ free", [bcf stringFromByteCount:srcVol.numberOfBytesPerBlock * srcVol.numberOfBlocksTotal], [bcf stringFromByteCount:srcVol.numberOfBytesPerBlock * srcVol.numberOfBlocksUsed], [bcf stringFromByteCount:srcVol.numberOfBytesPerBlock * srcVol.numberOfBlocksFree]]];

	bool const grabAnyFileWithThisName = ! [self isHFSPath:self.quarryNameOrPath];
	NSArray <NSString *> *_Nonnull const parsedPath = [self parseHFSPath:self.quarryNameOrPath];

	//TODO: If it *is* a path, trace that path through the catalog.

	ImpBTreeFile *_Nonnull const catalog = srcVol.catalogBTree;
	ImpBTreeHeaderNode *_Nonnull const headerNode = catalog.headerNode;
	NSMutableSet *_Nonnull const nodesPreviouslyEncountered = [NSMutableSet setWithCapacity:headerNode.numberOfTotalNodes];
	[catalog walkBreadthFirst:^bool(ImpBTreeNode *_Nonnull const node) {
		if ([nodesPreviouslyEncountered containsObject:@(node.nodeNumber)]) {
			return true;
		}
		ImpPrintf(@"Walk encountered node: %@", node);
		[nodesPreviouslyEncountered addObject:@(node.nodeNumber)];

		if (node.nodeType == kBTLeafNode) {
			[node forEachCatalogRecord_file:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFile *const _Nonnull fileRec) {
				ImpDehydratedItem *_Nonnull const dehydratedFile = [[ImpDehydratedItem alloc] initWithHFSVolume:srcVol catalogNodeID:L(fileRec->fileID) key:catalogKeyPtr fileRecord:fileRec];
//				ImpPrintf(@"We're looking for “%@” and found a file named “%@”", self.quarryName, dehydratedFile.name);
				bool const nameIsEqual = [dehydratedFile.name isEqualToString:self.quarryName];
				bool const shouldRehydrateBecauseName = (grabAnyFileWithThisName && nameIsEqual);
				bool const shouldRehydrateBecausePath = nameIsEqual && [self isQuarryPath:parsedPath isEqualToCatalogPath:dehydratedFile.path];
				if (shouldRehydrateBecauseName || shouldRehydrateBecausePath) {
					//TODO: Need to implement the smarter destination path logic promised in the help. This requires the user to specify the destination path including filename.
					ImpPrintf(@"Found an item named %@ with parent item #%u", dehydratedFile.name, dehydratedFile.parentFolderID);
					NSString *_Nonnull const destPath = self.destinationPath ?: [dehydratedFile.name stringByReplacingOccurrencesOfString:@"/" withString:@":"];
					rehydrated = [dehydratedFile rehydrateAtRealWorldURL:[NSURL fileURLWithPath:destPath isDirectory:false] error:outError];
					if (! rehydrated) {
						ImpPrintf(@"Failed to rehydrate file named %@: %@", dehydratedFile.name, *outError);
					}
				}
			} folder:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFolder *const _Nonnull folderRec) {
				//TODO: Implement me
			} thread:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogThread *const _Nonnull threadRec) {
				//Ignore thread records.
			}];
			return ! rehydrated;
		}

		return true;
	}];
	NSLog(@"%@", rehydrated ? @"Success!" : @"Failure");
	return rehydrated;
}

@end
