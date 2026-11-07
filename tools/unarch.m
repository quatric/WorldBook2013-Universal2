#import <Foundation/Foundation.h>
// typedstream (NSArchiver) -> XML plist
static id clean(id o) {
	if ([o isKindOfClass:[NSDictionary class]]) { NSMutableDictionary *d = [NSMutableDictionary dictionary]; for (id k in o) d[[k description]] = clean(o[k]); return d; }
	if ([o isKindOfClass:[NSArray class]]) { NSMutableArray *a = [NSMutableArray array]; for (id x in o) [a addObject:clean(x)]; return a; }
	if ([o isKindOfClass:[NSString class]] || [o isKindOfClass:[NSNumber class]] || [o isKindOfClass:[NSData class]] || [o isKindOfClass:[NSDate class]]) return o;
	return [NSString stringWithFormat:@"<%@> %@", [o class], o];
}
int main(int argc, char **argv) {
	NSData *d = [NSData dataWithContentsOfFile:@(argv[1])];
	id o = [NSUnarchiver unarchiveObjectWithData:d];
	NSData *x = [NSPropertyListSerialization dataWithPropertyList:clean(o) format:NSPropertyListXMLFormat_v1_0 options:0 error:NULL];
	[x writeToFile:@(argv[2]) atomically:YES];
	return 0;
}
