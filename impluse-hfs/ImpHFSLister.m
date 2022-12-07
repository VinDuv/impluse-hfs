//
//  ImpHFSLister.m
//  impluse-hfs
//
//  Created by Peter Hosey on 2022-12-06.
//

#import "ImpHFSLister.h"

#import "ImpHFSVolume.h"
#import "ImpDehydratedItem.h"

@implementation ImpHFSLister

- (bool)performInventoryOrReturnError:(NSError *_Nullable *_Nonnull) outError {
	int const readFD = open(self.sourceDevice.fileSystemRepresentation, O_RDONLY);
	if (readFD < 0) {
		NSError *_Nonnull const cantOpenForReadingError = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:@{ NSLocalizedDescriptionKey: @"Can't open source device for reading" }];
		if (outError != NULL) *outError = cantOpenForReadingError;
		return false;
	}

	ImpHFSVolume *_Nonnull const srcVol = [[ImpHFSVolume alloc] initWithFileDescriptor:readFD];
	if (! [srcVol loadAndReturnError:outError])
		return false;

	ImpDehydratedItem *_Nonnull const rootDirectory = [ImpDehydratedItem rootDirectoryOfHFSVolume:srcVol];
	[rootDirectory printDirectoryHierarchy];
	return true;
}

@end