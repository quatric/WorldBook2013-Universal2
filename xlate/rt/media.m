// QuickTime, QTKit and other APIs that no longer exist.
#import <Foundation/Foundation.h>
#include "rt.h"

XLShim xl_find_media_shim(const char *name)
{
	(void)name;
	return NULL;
}
