//
//  ImpHFSAnalyzer.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-31.
//

#import "ImpHFSAnalyzer.h"

#import "ImpSizeUtilities.h"
#import "ImpTextEncodingConverter.h"

#import "ImpHFSVolume.h"
#import "ImpHFSPlusVolume.h"
#import "ImpVolumeProbe.h"
#import "ImpBTreeFile.h"
#import "ImpBTreeNode.h"
#import "ImpBTreeHeaderNode.h"
#import "ImpBTreeIndexNode.h"

@interface ImpHFSAnalyzer ()

- (bool) analyzeVolume:(ImpHFSVolume *_Nonnull const)srcVol error:(NSError *_Nullable *_Nonnull) outError;

@end
@implementation ImpHFSAnalyzer

- (bool)performAnalysisOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	int const readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}

	__block bool analyzed = false;
	__block NSError *_Nullable volumeLoadError = nil;
	__block NSError *_Nullable analysisError = nil;

	ImpVolumeProbe *_Nonnull const probe = [[ImpVolumeProbe alloc] initWithFileDescriptor:readFD];
	[probe findVolumes:^(const u_int64_t startOffsetInBytes, const u_int64_t lengthInBytes, Class  _Nullable const __unsafe_unretained volumeClass) {
		ImpHFSVolume *_Nonnull const srcVol = [[volumeClass alloc] initWithFileDescriptor:readFD startOffsetInBytes:startOffsetInBytes lengthInBytes:lengthInBytes textEncoding:self.hfsTextEncoding];
		analyzed = ([srcVol loadAndReturnError:&volumeLoadError] && [self analyzeVolume:srcVol error:&analysisError]) || analyzed;
	}];

	if (! analyzed) {
		if (outError != NULL) {
			*outError = volumeLoadError ?: analysisError;
		}
	}

	return analyzed;
}
- (bool) analyzeVolume:(ImpHFSVolume *_Nonnull const)srcVol error:(NSError *_Nullable *_Nonnull) outError {
	if ([srcVol isKindOfClass:[ImpHFSPlusVolume class]]) {
		ImpHFSPlusVolume *_Nonnull const srcVolPlus = (ImpHFSPlusVolume *_Nonnull const)srcVol;
		[srcVolPlus peekAtHFSPlusVolumeHeader:^(NS_NOESCAPE const struct HFSPlusVolumeHeader *const vhPtr) {
			ImpPrintf(@"Found HFS+ volume");

			NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
			fmtr.numberStyle = NSNumberFormatterDecimalStyle;
			fmtr.hasThousandSeparators = true;

			struct HFSPlusExtentDescriptor const *_Nonnull const catExtDescs = vhPtr->catalogFile.extents;
			ImpPrintf(@"Catalog extent record pointer: %p", catExtDescs);
			for (NSUInteger i = 0; i < kHFSPlusExtentDensity && catExtDescs[i].blockCount > 0; ++i) {
				ImpPrintf(@"Catalog extent #%lu: start block #%@, length %@ blocks", i, [fmtr stringFromNumber:@(L(catExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[0].blockCount))]);
			}

			struct HFSPlusExtentDescriptor const *_Nonnull const eoExtDescs = vhPtr->extentsFile.extents;
			for (NSUInteger i = 0; i < kHFSPlusExtentDensity && eoExtDescs[i].blockCount > 0; ++i) {
				ImpPrintf(@"Extents overflow extent #%lu: start block #%@, length %@ blocks", i, [fmtr stringFromNumber:@(L(eoExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[0].blockCount))]);
			}
		}];
	} else {
		[srcVol peekAtHFSVolumeHeader:^(NS_NOESCAPE const struct HFSMasterDirectoryBlock *const mdbPtr) {
			ImpPrintf(@"Found HFS volume with name: %@", [srcVol.textEncodingConverter stringForPascalString:mdbPtr->drVN]);

			NSNumberFormatter *_Nonnull const fmtr = [NSNumberFormatter new];
			fmtr.numberStyle = NSNumberFormatterDecimalStyle;
			fmtr.hasThousandSeparators = true;

			struct HFSExtentDescriptor const *_Nonnull const catExtDescs = mdbPtr->drCTExtRec;
			ImpPrintf(@"Catalog extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[0].blockCount))]);
			ImpPrintf(@"Catalog extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[1].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[1].blockCount))]);
			ImpPrintf(@"Catalog extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(catExtDescs[2].startBlock))], [fmtr stringFromNumber:@(L(catExtDescs[2].blockCount))]);

			struct HFSExtentDescriptor const *_Nonnull const eoExtDescs = mdbPtr->drXTExtRec;
			ImpPrintf(@"Extents overflow extent the first: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[0].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[0].blockCount))]);
			ImpPrintf(@"Extents overflow extent the second: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[1].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[1].blockCount))]);
			ImpPrintf(@"Extents overflow extent the third: start block #%@, length %@ blocks", [fmtr stringFromNumber:@(L(eoExtDescs[2].startBlock))], [fmtr stringFromNumber:@(L(eoExtDescs[2].blockCount))]);
		}];
	}
	if (! [srcVol readAllocationBitmapFromFileDescriptor:srcVol.fileDescriptor error:outError]) {
		ImpPrintf(@"Failed to read allocation bitmap: %@", (*outError).localizedDescription);
		return false;
	}
	if (! [srcVol readExtentsOverflowFileFromFileDescriptor:srcVol.fileDescriptor error:outError]) {
		ImpPrintf(@"Failed to read extents overflow file: %@", (*outError).localizedDescription);
		return false;
	}
	if (! [srcVol readCatalogFileFromFileDescriptor:srcVol.fileDescriptor error:outError]) {
		ImpPrintf(@"Failed to read catalog file: %@", (*outError).localizedDescription);
		return false;
	}

	u_int32_t const blockSize = (u_int32_t)srcVol.numberOfBytesPerBlock;
	void (^_Nonnull const logFork)(char const *_Nonnull const indentString, char const *_Nonnull const forkName, HFSPlusForkData const *_Nonnull const forkPtr) = ^(char const *_Nonnull const indentString, char const *_Nonnull const forkName, HFSPlusForkData const *_Nonnull const forkPtr) {
		u_int64_t const numBlocksFromExtentRec = ImpNumberOfBlocksInHFSPlusExtentRecord(forkPtr->extents);
		u_int64_t const lsize = L(forkPtr->logicalSize);
		u_int64_t const psize = L(forkPtr->totalBlocks) * blockSize;
		u_int64_t const esize = numBlocksFromExtentRec * blockSize;
		ImpPrintf(@"%s%s: lsize %llu, psize %u blocks (%llu bytes), extent sum %llu blocks (%llu bytes)",
			indentString, forkName,
			lsize,
			L(forkPtr->totalBlocks), psize,
			numBlocksFromExtentRec, esize
		);
		if (lsize > psize) {
			ImpPrintf(@"%s🚨 %s: lsize is greater than psize. Likely causes: Endianness issue; stale/incorrect psize.", indentString, forkName);
		}
		if (psize != esize) {
			ImpPrintf(@"%s🚨 %s: psize (totalBlocks) does not match sum of extent blockCounts. Likely causes: Endianness issue; one or both are stale/incorrect.", indentString, forkName);
		}
		ImpPrintf(@"%s%s extents: %@", indentString, forkName, ImpDescribeHFSPlusExtentRecord(forkPtr->extents));
	};

	ImpPrintf(@"Volume's name is “%@”", srcVol.volumeName);
	ImpPrintf(@"“%@” contains %lu files and %lu folders", srcVol.volumeName, srcVol.numberOfFiles, srcVol.numberOfFolders);
	NSByteCountFormatter *_Nonnull const bcf = [NSByteCountFormatter new];
	ImpPrintf(@"Allocation block size is %lu (%lx) bytes; volume has %lu blocks in use, %lu free", srcVol.numberOfBytesPerBlock, srcVol.numberOfBytesPerBlock, srcVol.numberOfBlocksUsed, srcVol.numberOfBlocksFree);
	if ([srcVol isKindOfClass:[ImpHFSPlusVolume class]]) {
		ImpHFSPlusVolume *_Nonnull const srcVolPlus = (ImpHFSPlusVolume *_Nonnull const)srcVol;
		[srcVolPlus peekAtHFSPlusVolumeHeader:^(NS_NOESCAPE const struct HFSPlusVolumeHeader *const vhPtr) {
			ImpPrintf(@"Volume attributes: 0x%08x", L(vhPtr->attributes));
			ImpPrintf(@"Creation date: %u", L(vhPtr->createDate));
			ImpPrintf(@"Space remaining (from volume header): %u blocks (0x%llx bytes)", L(vhPtr->freeBlocks), L(vhPtr->freeBlocks) * (u_int64_t)srcVolPlus.numberOfBytesPerBlock);
			u_int32_t const numBitsFreeInBitmap = [srcVol numberOfBlocksFreeAccordingToBitmap];
			ImpPrintf(@"Space remaining (from allocations bitmap): %u blocks (0x%llx bytes)", numBitsFreeInBitmap, numBitsFreeInBitmap * (u_int64_t)srcVolPlus.numberOfBytesPerBlock);
			ImpPrintf(@"Clump size for data forks is 0x%llx (0x200 * %.1f; ABS * %.1f)", (u_int64_t)L(vhPtr->dataClumpSize), L(vhPtr->dataClumpSize) / (double)kISOStandardBlockSize, L(vhPtr->dataClumpSize) / (double)srcVolPlus.numberOfBytesPerBlock);
			ImpPrintf(@"Clump size for resource forks is 0x%llx (0x200 * %.1f; ABS * %.1f)", (u_int64_t)L(vhPtr->dataClumpSize), L(vhPtr->dataClumpSize) / (double)kISOStandardBlockSize, L(vhPtr->dataClumpSize) / (double)srcVolPlus.numberOfBytesPerBlock);
			logFork("", "Allocations file", &(vhPtr->allocationFile));
			logFork("", "Extents overflow file", &(vhPtr->extentsFile));
			logFork("", "Catalog file", &(vhPtr->catalogFile));
		}];
	} else {
		[srcVol peekAtHFSVolumeHeader:^(NS_NOESCAPE struct HFSMasterDirectoryBlock const *_Nonnull const mdbPtr) {
			ImpPrintf(@"Creation date: %u", L(mdbPtr->drCrDate));
			ImpPrintf(@"First allocation block: 0x%llx", (u_int64_t)(L(mdbPtr->drAlBlSt) * kISOStandardBlockSize));
			ImpPrintf(@"Space remaining: %u blocks (0x%llx bytes)", L(mdbPtr->drFreeBks), (u_int64_t)(L(mdbPtr->drFreeBks) * L(mdbPtr->drAlBlkSiz)));
			ImpPrintf(@"Clump size is 0x%llx (0x200 * %.1f; ABS * %.1f)", (u_int64_t)L(mdbPtr->drClpSiz), L(mdbPtr->drClpSiz) / (double)kISOStandardBlockSize, L(mdbPtr->drClpSiz) / (double)L(mdbPtr->drAlBlkSiz));
		}];
	}
	ImpPrintf(@"Volume size is %@; %@ in use, %@ free", [bcf stringFromByteCount:srcVol.numberOfBytesPerBlock * srcVol.numberOfBlocksTotal], [bcf stringFromByteCount:srcVol.numberOfBytesPerBlock * srcVol.numberOfBlocksUsed], [bcf stringFromByteCount:srcVol.numberOfBytesPerBlock * srcVol.numberOfBlocksFree]);

	ImpBTreeFile *_Nonnull const catalog = srcVol.catalogBTree;
	ImpPrintf(@"Slurped catalog file: %@", catalog);
	fflush(stdout);

	ImpBTreeNode *_Nonnull const firstNode = [catalog nodeAtIndex:0];
	NSAssert(firstNode != nil, @"Empty catalog file! %@", catalog);
	NSAssert(firstNode.nodeType == kBTHeaderNode, @"First node in catalog must be a header node, but it was actually a %@", firstNode.nodeTypeName);

	ImpBTreeHeaderNode *_Nonnull const headerNode = (ImpBTreeHeaderNode *_Nonnull const)firstNode;
	u_int32_t const numLiveNodes = headerNode.numberOfTotalNodes - headerNode.numberOfFreeNodes;
	ImpPrintf(@"Header node portends %u total nodes, of which %u are free (= %u used)", headerNode.numberOfTotalNodes, headerNode.numberOfFreeNodes, numLiveNodes);

	ImpBTreeNode *_Nonnull const rootNode = headerNode.rootNode;
	ImpPrintf(@"Root node is %@", rootNode);

	__block NSUInteger numNodes = 0;
	__block NSUInteger lastEncounteredHeight = rootNode.nodeHeight;
	__block NSUInteger numNodesThisRow = 0;
	NSMutableArray <NSString *> *_Nonnull const nodeIndexStrings = [NSMutableArray arrayWithCapacity:numLiveNodes];
	NSMutableArray <NSString *> *_Nonnull const indexNodePointerCountStrings = [NSMutableArray arrayWithCapacity:numLiveNodes];
	__block NSUInteger numNodesPointedToByPointerRecordsThisRow = 0;
	NSMutableArray <NSString *> *_Nonnull const indexNodeContentsStrings = [NSMutableArray arrayWithCapacity:numLiveNodes];

	NSString *_Nonnull (^_Nonnull const abbreviateFilename)(ConstStr31Param) = ^NSString *_Nonnull(ConstStr31Param nodeName) {
		NSString *_Nonnull const fullName = [srcVol.textEncodingConverter stringForPascalString:nodeName];
		if (fullName.length <= 3) {
			return fullName;
		}
		return [fullName stringByReplacingCharactersInRange:(NSRange){ 3, fullName.length - 3 } withString:@"…"];
	};

	NSString *_Nonnull (^_Nonnull const emojiForNodeType)(BTreeNodeKind kind) = ^NSString *_Nonnull(BTreeNodeKind kind) {
		switch (kind) {
			case kBTLeafNode:
				return @"🍁";
			case kBTIndexNode:
				return @"🗂";
			case kBTHeaderNode:
				return @"👤";
			case kBTMapNode:
				return @"🗺";
			default:
				return @"💣";
		}
	};

	NSMutableSet *_Nonnull const nodesPreviouslyEncountered = [NSMutableSet setWithCapacity:headerNode.numberOfTotalNodes];
	[catalog walkBreadthFirst:^bool(ImpBTreeNode *_Nonnull const node) {
		if ([nodesPreviouslyEncountered containsObject:@(node.nodeNumber)]) {
			ImpPrintf(@"Walk encountered node AGAIN(???): %@", node);
			return true;
		}
		[nodesPreviouslyEncountered addObject:@(node.nodeNumber)];
		++numNodes;

		NSUInteger const thisHeight = node.nodeHeight;
		if (thisHeight != lastEncounteredHeight) {
			if (lastEncounteredHeight != NSUIntegerMax) {
				ImpPrintf(@"%lu:\t%lu\t(%@)", lastEncounteredHeight, numNodesThisRow, [nodeIndexStrings componentsJoinedByString:@", "]);
				if (indexNodePointerCountStrings.count > 0) {
					ImpPrintf(@"⬇️⬇️⬇️:\t\t(%@) = %lu", [indexNodePointerCountStrings componentsJoinedByString:@" + "], numNodesPointedToByPointerRecordsThisRow);
					ImpPrintf(@"⬇️⬇️⬇️:\t\t(\n\t%@\n\t)", [indexNodeContentsStrings componentsJoinedByString:@",\n\t"]);
				}
			}
			lastEncounteredHeight = thisHeight;
			numNodesThisRow = 0;
			[nodeIndexStrings removeAllObjects];
			[indexNodePointerCountStrings removeAllObjects];
			numNodesPointedToByPointerRecordsThisRow = 0;
			[indexNodeContentsStrings removeAllObjects];
		}

		++numNodesThisRow;

		NSString *_Nonnull const emoji = emojiForNodeType(node.nodeType);
		[nodeIndexStrings addObject:[NSString stringWithFormat:@"%@%u(%u)", emoji, (u_int32_t)node.nodeNumber, node.numberOfRecords]];
		if (node.nodeType == kBTIndexNode) {
			ImpBTreeIndexNode *_Nonnull const indexNode = (ImpBTreeIndexNode *_Nonnull const)node;
			[indexNodePointerCountStrings addObject:[NSString stringWithFormat:@"%u", indexNode.numberOfRecords]];
			numNodesPointedToByPointerRecordsThisRow += indexNode.numberOfRecords;

			NSMutableArray *_Nonnull const pointerRecordDescriptions = [NSMutableArray arrayWithCapacity:indexNode.numberOfRecords];
			[indexNode forEachKeyedRecord:^bool(NSData *const  _Nonnull keyData, NSData *const  _Nonnull payloadData) {
				struct HFSCatalogKey const *_Nonnull const keyPtr = keyData.bytes;
				u_int32_t const *_Nonnull const nodeIndexPtr = payloadData.bytes;
				NSString *_Nonnull const desc = [NSString stringWithFormat:@"📦%u\"%@\"➡️%@%u", L(keyPtr->parentID), abbreviateFilename(keyPtr->nodeName), emojiForNodeType([catalog nodeAtIndex:L(*nodeIndexPtr)].nodeType), L(*nodeIndexPtr)];
				[pointerRecordDescriptions addObject:desc];
				return true;
			}];
			[indexNodeContentsStrings addObject:[NSString stringWithFormat:@"🗂%u [ %@ ]", indexNode.nodeNumber, [pointerRecordDescriptions componentsJoinedByString:@", "]]];
		}

		return true;
	}];
	if (lastEncounteredHeight != NSUIntegerMax) {
		ImpPrintf(@"%lu:\t%lu\t(%@)", lastEncounteredHeight, numNodesThisRow, [nodeIndexStrings componentsJoinedByString:@","]);
	}

	__block NSUInteger numFiles = 0, numFolders = 0, numThreads = 0;

	[catalog walkBreadthFirst:^bool(ImpBTreeNode *_Nonnull const node) {
		if (node.nodeType == kBTLeafNode) {
			//Each of these will only return HFS or HFS+ catalog entries, so call both. If it's an HFS volume, we'll get HFS entries; if it's HFS+, we'll get HFS+ entries.
			[node forEachHFSCatalogRecord_file:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFile *const _Nonnull fileRec) {
				ImpPrintf(@"- 📄 “%@”, ID #%u (0x%x), type %@ creator %@", [srcVol.textEncodingConverter stringForPascalString:catalogKeyPtr->nodeName], L(fileRec->fileID), L(fileRec->fileID),  NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdType)), NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdCreator)));
				ImpPrintf(@"    Parent ID: #%u (0x%x)", L(catalogKeyPtr->parentID), L(catalogKeyPtr->parentID));
				++numFiles;
			} folder:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogFolder *const _Nonnull folderRec) {
				struct FndrExtendedFileInfo const *_Nonnull const extFinderInfo = (struct FndrExtendedFileInfo const *)&(folderRec->finderInfo);
				ImpPrintf(@"- 📁 “%@” with ID #%u, %u items", [srcVol.textEncodingConverter stringForPascalString:catalogKeyPtr->nodeName], L(folderRec->folderID), L(folderRec->valence));
				ImpPrintf(@"    Node flags: 0x%04x", L(folderRec->flags));
				ImpPrintf(@"    Finder flags: 0x%04x + 0x%04x", L(folderRec->userInfo.frFlags), L(extFinderInfo->extended_flags));
				ImpPrintf(@"    Creation date: %u", L(folderRec->createDate));
				++numFolders;
			} thread:^(struct HFSCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSCatalogThread *const _Nonnull threadRec) {
				u_int32_t const ownID = L(catalogKeyPtr->parentID);
				u_int32_t const parentID = L(threadRec->parentID);
				ImpPrintf(@"- %@🧵 puts item #%u, with name “%@”, in parent ID #%u", L(threadRec->recordType) == kHFSFileThreadRecord ? @"📄" : @"📁", ownID, [[srcVol.textEncodingConverter stringForPascalString:threadRec->nodeName] stringByReplacingOccurrencesOfString:@"\x0d" withString:@"\\r"], parentID);
				++numThreads;
			}];
			NSString *_Nonnull (^_Nonnull const flagsString)(u_int16_t const itemFlags, u_int16_t const finderFlags, u_int16_t const extFinderFlags) = ^NSString *_Nonnull (u_int16_t const itemFlags, u_int16_t const finderFlags, u_int16_t const extFinderFlags) {
				//avbstclinmedz (order used by GetFileInfo(1))
				return [NSString stringWithFormat:@"%c%c%c%c%c%c%c%c%c%c%c%c%c",
					finderFlags & kIsAlias ? 'A' : 'a',
						finderFlags & kIsInvisible ? 'V' : 'v',
						finderFlags & kHasBundle ? 'B' : 'b',
						finderFlags & kNameLocked ? 'S' : 's',
						finderFlags & kIsStationery ? 'T' : 't',
						finderFlags & kHasCustomIcon ? 'C' : 'c',
						itemFlags & kHFSFileLockedMask  ? 'L' : 'l',
						finderFlags & kHasBeenInited ? 'I' : 'i',
						finderFlags & kHasNoINITs ? 'N' : 'n',
						finderFlags & kIsShared ? 'M' : 'm',
						'.', //extension hidden—not sure how to get this
						finderFlags & kIsOnDesk ? 'D' : 'd',
						extFinderFlags & kExtendedFlagObjectIsBusy ? 'Z' : 'z'
				];
			};
			[node forEachHFSPlusCatalogRecord_file:^(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSPlusCatalogFile *const _Nonnull fileRec) {
				struct FndrExtendedFileInfo const *_Nonnull const extFinderInfo = (struct FndrExtendedFileInfo const *)&(fileRec->finderInfo);
				ImpPrintf(@"- 📄 “%@”, ID #%u (0x%x), type %@ creator %@, flags %@", [[srcVol.textEncodingConverter stringFromHFSUniStr255:&catalogKeyPtr->nodeName] stringByReplacingOccurrencesOfString:@"\x0d" withString:@"\\r"], L(fileRec->fileID), L(fileRec->fileID),  NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdType)), NSFileTypeForHFSTypeCode(L(fileRec->userInfo.fdCreator)), flagsString(L(fileRec->flags), L(fileRec->userInfo.fdFlags), L(extFinderInfo->extended_flags)));
				ImpPrintf(@"    Node flags: 0x%04x", L(fileRec->flags));
				ImpPrintf(@"    Finder flags: 0x%04x + 0x%04x", L(fileRec->userInfo.fdFlags), L(extFinderInfo->extended_flags));
				logFork("    ", "DF", &(fileRec->dataFork));
				logFork("    ", "RF", &(fileRec->resourceFork));
				++numFiles;
			} folder:^(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSPlusCatalogFolder *const _Nonnull folderRec) {
				struct FndrExtendedFileInfo const *_Nonnull const extFinderInfo = (struct FndrExtendedFileInfo const *)&(folderRec->finderInfo);
				ImpPrintf(@"- 📁 “%@” with ID #%u, %u items", [[srcVol.textEncodingConverter stringFromHFSUniStr255:&catalogKeyPtr->nodeName] stringByReplacingOccurrencesOfString:@"\x0d" withString:@"\\r"], L(folderRec->folderID), L(folderRec->valence));
				ImpPrintf(@"    Node flags: 0x%04x", L(folderRec->flags));
				ImpPrintf(@"    Finder flags: 0x%04x + 0x%04x", L(folderRec->userInfo.frFlags), L(extFinderInfo->extended_flags));
				ImpPrintf(@"    Creation date: %u", L(folderRec->createDate));
				++numFolders;
			} thread:^(struct HFSPlusCatalogKey const *_Nonnull const catalogKeyPtr, const struct HFSPlusCatalogThread *const _Nonnull threadRec) {
				u_int32_t const ownID = L(catalogKeyPtr->parentID);
				u_int32_t const parentID = L(threadRec->parentID);
				ImpPrintf(@"- %@🧵 puts item #%u, with name “%@”, in parent ID #%u", L(threadRec->recordType) == kHFSPlusFileThreadRecord ? @"📄" : @"📁", ownID, [[srcVol.textEncodingConverter stringFromHFSUniStr255:&threadRec->nodeName] stringByReplacingOccurrencesOfString:@"\x0d" withString:@"\\r"], parentID);
				++numThreads;
			}];
		}
		return true;
	}];
	ImpPrintf(@"Encountered %lu nodes", numNodes);
	ImpPrintf(@"Encountered %lu files, %lu folders (including root directory), %lu threads", numFiles, numFolders, numThreads);
	ImpPrintf(@"Volume header says it has %lu files, %lu folders (excluding root directory)", (unsigned long)srcVol.numberOfFiles, (unsigned long)srcVol.numberOfFolders);

	return true;
}

@end
