//
//	MenuCracker.m
//
//	This file is a part of MenuCracker 2.x (http://sourceforge.net/projects/menucracker)
//
//	Copyright 2009 Alex Harper, basilisk@foobox.net
//	Based on MenuCracker 1.x Copyright 2001-2008, james_007_bond@users.sourceforge.net
//
//	See Artistic License.rtf for license information.
//
//
//  =====================================================================
//  WARNING!! PLEASE READ BEFORE HACKING!
//  =====================================================================
//
//  MenuCracker 2.x has a complex mechanism for handling forwards and
//  backwards compatibility using a versioned indirection table.
//
//  If you are making changes for a new Apple OS X release or responding to
//  any other change to SystemUIServer you _MUST_ correctly upgrade the
//  indirection table. Failure to follow the design requirements with your
//  changes will probably cause MenuCracker to crash as soon as a user installs
//  an unhacked copy of MenuCracker.
//
//  Before making changes for a new OS X version please read "Design Notes"
//  below and make sure you follow the existing pattern for
//  kCrackerCooperationRecordVersion and indirection table layout.
//
//  Even better, please consider contacting the author basilisk@foobox.net
//  for assistance coordinating your changes with the standard release.
//
//  If you plan to fork MenuCracker publicly please consider changing the name,
//  bundle ID, and indirection global name of your fork so that your changes do
//  not interfere with new versions of the standard release.
//
//  =====================================================================
//  WARNING!! PLEASE READ BEFORE HACKING!
//  =====================================================================
//
//
//	Design Notes:
//	=============
//
//	This is a reimplementation of the original MenuCracker. Though it serves
//	the same purpose, this implementation's design differs in several important
//	ways.
//
//	New Loader
//	----------
//	In this design the loading mechanism is changed. When SystemUIServer
//	(SUIS) decides to load a NSMenuExtra it looks at the NSPrincipalClass key of
//	the bundle's Info.plist to decide if it will allow the class (string
//	comparison). If the principal class is on the whitelist the bundle is
//	loaded and an instance of the principal class is sent through the plumbing.
//
//	Prior versions of MenuCracker worked by defining an empty implementation
//	of the CHUD tools processor extra (CPUExtra) and then loading the crack
//	class out of the same bundle. The problem with this approach was that it
//	permanently blocked the load of the actual CHUD menu. Redefinition of an
//	existing runtime class is undefined in Obj-C, and so the empty class from
//	the cracker kept winning. Similarly, if an old version of MenuCracker was
//	loaded it would prevent newer versions from loading (because the cracker
//	class was already defined). This was a common bug, especially with very
//	old copies of MenuCracker bundled with some software.
//
//	This version of the cracker tricks SUIS in a different way. It declares
//	an NSPrincipalClass on the whitelist, but doesn't implement it. When
//	SUIS loads the bundle a constructor function handles the menu cracking.
//	Since this implementation declares nothing in the Obj-C runtime and uses
//	all private symbols it can be loaded safely multiple times in the same SUIS.
//
//	Multi-Version Cooperative Loading
//	---------------------------------
//	A second major difference in design is the handling of multiple versions
//	of MenuCracker itself. Not every developer bundling MenuCracker has kept
//	up to date and even if they did not every end user will update their
//	software regularly.
//
//	Prior versions of MenuCracker assumed that eventually the new version of
//	MenuCracker would be loaded because old copies sorted the crackers in
//	SUIS's list of menu extras by comparing version numbers. Unfortunately in
//	practice this mechanism sometimes failed, usually because of bugs in the
//	older implementation. The most common failure was the problem with CPUExtra
//	class redefinition discussed above, but other bugs with path validation,
//	etc. have also been problems.
//
//	This implementation takes a new approach. First and foremost, the new
//	load design (see above) allows multiple MenuCrackers to load at once.
//	Rather than try to resolve this down to a single winner which gets
//	loaded first, we now use a cooperative approach that allows newer versions
//	loaded later to overtake previously loaded versions.
//
//	The first MenuCracker to load establishes a global in SUIS that contains
//	an indirection table. SUIS methods are swizzled to redirection routines
//	that then call through the table to the desired implementation.
//
//	When a second MenuCracker loads it has access to the indirection table and
//	can coordinate with the original MenuCracker to decide which version is
//	"best". If the second copy wins it replaces the indirection table content
//	with its own, completely taking all but the redirection calls from the
//	first MenuCracker out of the code path.
//
//	Since each method of SUIS is swizzled only once for all MenuCrackers
//	other tools that swizzle the same routines are safe. Secondary swizzlers
//	always have valid pointers to the first loaded redirection routines. If
//	new swizzles are needed for later versions they can be added to the
//	indirection table using newer redirection routines but still leaving
//	the older redirection routines in place.
//
//	Less Aggressive Housekeeping
//	----------------------------
//	Once upon a time we checked for other loaded crackers, specifically
//	old versions of MenuCracker or Enable.menu from older Keychain Access.
//	If they were loaded we went through a restart dance to try to become
//	the only loaded cracker (assuming we won the version comparison) by
//	rewriting the SUIS preferences and killing SUIS. The problem with that
//	approach was twofold:
//
//	- In the real world SystemUIServer never loaded duplicate MenuCrackers
//	  (see above).
//	- The most common alternate cracker, Unsanity MEE, couldn't be unloaded
//	  by modifying the preferences and restarting SUIS.
//
//	It's not clear there's any advantage to trying to be the only cracker.
//	This design doesn't require it, so we don't even try. We only remove
//	old MenuCrackers from the next load and try to peacefully coexist with
//	whatever else is loaded.

#import <Cocoa/Cocoa.h>
#import <objc/objc-class.h>
#import <dlfcn.h>


#pragma mark Utilities

// Helper for looking up our own bundle path. Since this bundle contains
// no classes of its own the usual "bundleForClass:" stuff doesn't work.
// We don't want to look up by ID because we can be loaded many
// times with the same ID at different paths.
//
// This doesn't handle the user relocating the file after load, but then again,
// neither does SUIS.
static NSString * SelfBundlePath(void) {
	Dl_info info;
	// Use our own address, it must be in this image, right?
	// Yes, dladdr really does return non-zero for success, see the man page.
	if (dladdr(&SelfBundlePath, &info)) {
		NSString *path = [[NSFileManager defaultManager]
							stringWithFileSystemRepresentation:info.dli_fname
														length:strlen(info.dli_fname)];
		// Strip Contents/MacOS/MenuCracker
		path = [[[path stringByDeletingLastPathComponent]
					stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
		return [path stringByStandardizingPath];
	} else {
		return nil;
	}
} // SelfBundlePath

// Convenience function for an autoreleased instance of our own bundle.
static NSBundle * SelfBundle(void) {
	NSString *path = SelfBundlePath();
	if (!path) return nil;
	return [NSBundle bundleWithPath:path];
} // SelfBundle

// Convenience function for autoreleased CFBundleVersion string from a bundle.
static NSString * BundleVersionString(NSBundle *bundle) {
	return [[bundle infoDictionary] objectForKey:(NSString *)kCFBundleVersionKey];
} // BundleVersionString

// Simple swizzler. This is _not_ a good general implementation (for example,
// it doesn't handle the case where the instance method is actually on the
// superclass). For SUISStartupObject we don't care.
// See Objective-C 2.0 Runtime Programming Guide for info on type encodings,
// we need them for x86_64 which is Obj-C 2.0 only.
static BOOL SimpleSwizzle(Class cls, SEL sel, IMP newImp, IMP *oldImp, const char *types) {
	// Sanity
	if (!cls) return NO;

#ifdef __LP64__
	IMP currentImp = class_replaceMethod(cls, sel, newImp, types);
	if (currentImp) {
		if (oldImp) *oldImp = currentImp;
		return YES;
	} else {
		return NO;
	}
#else
	// Replace
	Method method = class_getInstanceMethod(cls, sel);
	if (!method) return NO;
	if (oldImp) *oldImp = method->method_imp;
	method->method_imp = newImp;
	return YES;
#endif
} // SimpleSwizzle

// Check if a class implements an instance method
static BOOL ClassInstanceRespondsToSelector(Class cls, SEL sel) {
	return class_getInstanceMethod(cls, sel) ? YES : NO;
}

// Helper routine that determines if a bundle is an old version of MenuCracker
static BOOL IsBlockedOldBundle(NSBundle *bundle) {
	if ([[bundle bundleIdentifier] isEqualToString:@"net.sourceforge.menucracker"] ||
		[[bundle bundleIdentifier] isEqualToString:@"net.sourceforge.menucracker2"]) {
		return YES;
	} else {
		return NO;
	}
} // IsBlockedOldBundle


#pragma mark Cracker Cooperation

// Typedefs of the original SUIS methods we'll be swizzling
typedef BOOL (*SUIS_canLoadClass_IMP)(id, SEL, NSString *);
typedef id (*SUIScreateMenuExtra_atPosition_write_data_IMP)(id, SEL, id, unsigned int, BOOL, void *);  // 10.6 and earlier
typedef id (*SUIScreateMenuExtra_atPosition_write_data_initExtra_IMP)(id, SEL, id, unsigned int, BOOL, void *, BOOL);  // 10.7
typedef void (*SUISwriteMenuBarPlugins_IMP)(id, SEL, id);

// Type signatures for Obj-C 2.0 swizzle
#define kSUIS_canLoadClass_TypeSignature (const char *)"B@:@"
#define kSUIScreateMenuExtra_atPosition_write_data_TypeSignature (const char *)"@@:@Ic?"  // 10.6 and earlier
#define kSUIScreateMenuExtra_atPosition_write_data_initExtra_TypeSignature (const char *)"@@:@Ic?c"  // 10.7
#define kSUISwriteMenuBarPlugins_TypeSignature (const char *)"v@:@"


// Declarations for the global structures used to coordinate multiple instances
// of MenuCracker 2.x. Change these _very_carefully_ or not at all. Don't
// reorder structures or redeclare types. We have to have this work across
// old versions and our ability to introspect is limited.

// Cross-version sanity check. Allows a previously loaded copy to veto
// the loading of a new instance.
typedef BOOL (*CrackerCooperationVetoFunction)(NSString *);

// Version of the cooperation structure.
#define kCrackerCooperationRecordVersion 2

// The struct used to coordinate. Don't reorder this record, extend only.
typedef struct {
	// Version 1 record
	uint32_t													version;
	NSString													*controllingCrackerPath;
	CrackerCooperationVetoFunction								controllingCrackerVeto;
	SUIS_canLoadClass_IMP										suis_canLoadClass_Original;
	SUIS_canLoadClass_IMP										suis_canLoadClass_Cracked;
	SUIScreateMenuExtra_atPosition_write_data_IMP				suiscreateMenuExtra_atPosition_write_data_Original;
	SUIScreateMenuExtra_atPosition_write_data_IMP				suiscreateMenuExtra_atPosition_write_data_Cracked;
	SUISwriteMenuBarPlugins_IMP									suiswriteMenuBarPlugins_Original;
	SUISwriteMenuBarPlugins_IMP									suiswriteMenuBarPlugins_Cracked;
	// Version 2 record
	SUIScreateMenuExtra_atPosition_write_data_initExtra_IMP		suiscreateMenuExtra_atPosition_write_data_initExtra_Original;
	SUIScreateMenuExtra_atPosition_write_data_initExtra_IMP		suiscreateMenuExtra_atPosition_write_data_initExtra_Cracked;
} CrackerCooperationRecord;


// The global symbol that we coordinate through. Every loaded cracker actually
// has a copy of this, but we can use dlsym() to find the one we want to share.
// This is our only visible symbol, make it clear and unlikely to conflict.
//
// You should NEVER use this value directly since we want to use the first
// one loaded only. Use gSharedCooperationRecord instead.
extern CrackerCooperationRecord *MenuCrackerGlobalCooperationRecord;
CrackerCooperationRecord *MenuCrackerGlobalCooperationRecord = NULL;


// This is the local pointer to the shared MenuCrackerGlobalCooperationRecord from
// the first loaded instance. Use this instead of MenuCrackerGlobalCooperationRecord.
static CrackerCooperationRecord **gSharedCooperationRecord = NULL;


// Redirection functions that call through our global record. These are
// the functions actually swizzled in, they call through to the implementation
// from whatever MenuCracker is currently deemed best.
static BOOL RedirectSUIS_canLoadClass_(id self, SEL sel, NSString *className) {
	if (gSharedCooperationRecord && *gSharedCooperationRecord &&
		(*gSharedCooperationRecord)->suis_canLoadClass_Cracked) {
		return (*((*gSharedCooperationRecord)->suis_canLoadClass_Cracked))(self, sel, className);
	} else {
		NSLog(@"MenuCracker: %s called without cooperation in place.", __func__);
		// Really nothing we can do. Kill ourself
		[[NSApplication sharedApplication] terminate:nil];
		return NO;  // Never get here
	}
} // RedirectSUIS_canLoadClass_

static id RedirectSUIScreateMenuExtra_atPosition_write_data_(id self, SEL sel,
															 NSBundle *newBundle, unsigned int position,
															 BOOL unknown1, void *unknown2) {
	if (gSharedCooperationRecord && *gSharedCooperationRecord &&
		(*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_Cracked) {
		return (*((*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_Cracked))
					(self, sel, newBundle, position, unknown1, unknown2);
	} else {
		NSLog(@"MenuCracker: %s called without cooperation in place.", __func__);
		// Really nothing we can do. Kill ourself
		[[NSApplication sharedApplication] terminate:nil];
		return nil;  // Never get here
	}
} // RedirectSUIScreateMenuExtra_atPosition_write_data_

static id RedirectSUIScreateMenuExtra_atPosition_write_data_initExtra_(id self, SEL sel,
																	   NSBundle *newBundle, unsigned int position,
																	   BOOL unknown1, void *unknown2, BOOL unknown3) {
	if (gSharedCooperationRecord && *gSharedCooperationRecord &&
		(*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_initExtra_Cracked) {
		return (*((*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_initExtra_Cracked))
		(self, sel, newBundle, position, unknown1, unknown2, unknown3);
	} else {
		NSLog(@"MenuCracker: %s called without cooperation in place.", __func__);
		// Really nothing we can do. Kill ourself
		[[NSApplication sharedApplication] terminate:nil];
		return nil;  // Never get here
	}
} // RedirectSUIScreateMenuExtra_atPosition_write_data_initExtra_

static void RedirectSUISwriteMenuBarPlugins_(id self, SEL sel, id unknown) {
	if (gSharedCooperationRecord && *gSharedCooperationRecord &&
		(*gSharedCooperationRecord)->suiswriteMenuBarPlugins_Cracked) {
		(*((*gSharedCooperationRecord)->suiswriteMenuBarPlugins_Cracked))(self, sel, unknown);
	} else {
		NSLog(@"MenuCracker: %s called without cooperation in place.", __func__);
		// Really nothing we can do but with a void return we don't have to
		// be fatal.
		return;
	}
} // RedirectSUISwriteMenuBarPlugins_


#pragma mark SystemUIServer Crack

static BOOL CrackedSUIS_canLoadClass_(id self, SEL sel, NSString *className) {
	// Call any original implementation for completeness (in case its another
	// cracker and needs the call for internal reasons)
	if (gSharedCooperationRecord && *gSharedCooperationRecord &&
		(*gSharedCooperationRecord)->suis_canLoadClass_Original) {
		if (!(*(*gSharedCooperationRecord)->suis_canLoadClass_Original)(self, sel, className)) {
			NSLog(@"MenuCracker: Allowing \"%@\".", className);
		}
		// Always say yes
		return YES;
	} else {
		// Nothing much sane we can do, but try to let it load
		NSLog(@"MenuCracker: %s called without original implementation.", __func__);
		return YES;
	}
} // CrackedSUIS_canLoadClass_

static id CrackedSUIScreateMenuExtra_atPosition_write_data_(id self, SEL sel,
															NSBundle *newBundle, unsigned int position,
															BOOL unknown1, void *unknown2) {
	// The only thing we block are versions of MenuCracker too old
	// to coordinate with us. We have a new bundle ID to make this easy.
	if (IsBlockedOldBundle(newBundle)) {
		NSLog(@"MenuCracker: Blocked load of pre-2.x MenuCracker.");
		return nil;
	}

	// Otherwise call through to original implementation
	if (gSharedCooperationRecord && *gSharedCooperationRecord &&
		(*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_Original) {
		return (*((*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_Original))
					(self, sel, newBundle, position, unknown1, unknown2);
	} else {
		// Nothing much sane we can do, but don't have to kill us
		NSLog(@"MenuCracker: %s called without original implementation.", __func__);
		return nil;
	}
} // CrackedSUIScreateMenuExtra_atPosition_write_data_

static id CrackedSUIScreateMenuExtra_atPosition_write_data_initExtra_(id self, SEL sel,
																	  NSBundle *newBundle, unsigned int position,
																	  BOOL unknown1, void *unknown2, BOOL unknown3) {
	// The only thing we block are versions of MenuCracker too old
	// to coordinate with us. We have a new bundle ID to make this easy.
	if (IsBlockedOldBundle(newBundle)) {
		NSLog(@"MenuCracker: Blocked load of pre-2.x MenuCracker.");
		return nil;
	}

	// Otherwise call through to original implementation
	if (gSharedCooperationRecord && *gSharedCooperationRecord &&
		(*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_initExtra_Original) {
		return (*((*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_initExtra_Original))
		(self, sel, newBundle, position, unknown1, unknown2, unknown3);
	} else {
		// Nothing much sane we can do, but don't have to kill us
		NSLog(@"MenuCracker: %s called without original implementation.", __func__);
		return nil;
	}
} // CrackedSUIScreateMenuExtra_atPosition_write_data_initExtra_

// Helper routine that makes sure MenuCracker is loaded by SystemUIServer
static void WriteCrackedSUISPreferences(void) {
	// We're loaded in SUIS so we can directly use its defaults.
	NSUserDefaults *suisDefaults = [NSUserDefaults standardUserDefaults];
	[suisDefaults synchronize];
	NSArray *currentExtras = [suisDefaults arrayForKey:@"menuExtras"];

#ifdef __LP64__
	NSUInteger i = 0;
#else
	unsigned int i = 0;
#endif
	NSMutableArray *newExtras = [NSMutableArray array];
	for (i = 0; i < [currentExtras count]; i++) {
		// Prior versions of this code did lots of housekeeping that SUIS
		// doesn't do itself like removing unloadable extras. Don't assume
		// we know better than SUIS. Just remove ourself and anything we
		// know is an older version. Don't even remove other copies of ourself.
		// Another version may be the best if we are uninstalled.
		NSString *extraPath = [[currentExtras objectAtIndex:i] stringByStandardizingPath];
		// Being on the list ourself is actually unlikely. Because we lie about
		// our principal class SUIS doesn't write us to this list. We're really
		// only looking for our own output.
		if ([extraPath isEqualToString:SelfBundlePath()]) {
			continue;
		}
		NSBundle *extraBundle = [NSBundle bundleWithPath:extraPath];
		if (IsBlockedOldBundle(extraBundle)) {
			continue;
		}
		// Want to keep it
		[newExtras addObject:[currentExtras objectAtIndex:i]];
	}

	// Now add ourself to the end of the array. We don't need to sort or
	// move any other instances of MenuCracker 2.x. Why? Because if this
	// function is running the cooperation code has decided that this
	// version is the best version. Other versions may appear in the list
	// but we're the one that wins.
	//
	// We must add ourself because the lying about our principal class
	// convinces SUIS not to add us.
	[newExtras addObject:SelfBundlePath()];
	[suisDefaults setObject:newExtras forKey:@"menuExtras"];
	[suisDefaults synchronize];
} // WriteCrackedSUISPreferences

static void CrackedSUISwriteMenuBarPlugins_(id self, SEL sel, id unknown) {
	if (gSharedCooperationRecord && *gSharedCooperationRecord &&
		(*gSharedCooperationRecord)->suiswriteMenuBarPlugins_Original) {

		// Let the original do its thing
		(*((*gSharedCooperationRecord)->suiswriteMenuBarPlugins_Original))(self, sel, unknown);
		// Then fix preferences to include ourself.
		WriteCrackedSUISPreferences();

	} else {
		NSLog(@"MenuCracker: %s called without cooperation in place.", __func__);
		// Really nothing we can do but with a void return we don't have to
		// be fatal.
		return;
	}
} // CrackedSUISwriteMenuBarPlugins_


#pragma mark Cracker Load

// Helper function for comparing ourself to some other copy of the cracker.
// If this instance is believed to be the "better" version returns YES.
static BOOL SelfIsTheBetterVersion(NSString *otherBundlePath) {
	// Check the bundles
	NSBundle *selfBundle = SelfBundle();
	NSBundle *otherBundle = [NSBundle bundleWithPath:otherBundlePath];
	if (!selfBundle || !otherBundle) {
		// In both these cases we don't have enough information so its
		// best to defer to the other instance. Maybe its newer and
		// has more information or some bugfix we don't know about.
		return NO;
	}

	// For this version (2.0-2.2) the only known check is a version comparison.
	// This implies we believe all future versions will use simple two-position
	// version numbers (2.x not 2.x.x).
	NSString *selfVersionString = BundleVersionString(selfBundle);
	NSString *otherVersionString = BundleVersionString(otherBundle);
	if (!selfVersionString || !otherVersionString) {
		// Again, a lack of information means we should defer to the other
		return NO;
	}
	if ([selfVersionString isEqualToString:otherVersionString]) {
		// Same version? We're not better.
		return NO;
	}
	if ([selfVersionString floatValue] > [otherVersionString floatValue]) {
		// We're greater (not just equal) so we should win
		return YES;
	} else {
		// We don't win the obvious checks. Defer to the other instance.
		return NO;
	}
} // SelfIsTheBetterVersion

// Helper function for the case where the cooperation record version is equal
// and we must do full version/veto logic.
static BOOL HandleSameRecordVersion(Class suisClass) {
	// Sanity check the structure for the rest of this code
	if (!(*gSharedCooperationRecord)->controllingCrackerPath) {
		NSLog(@"MenuCracker: Cooperation record missing controlling cracker path, can't load.");
		return NO;
	}
	if (!(*gSharedCooperationRecord)->controllingCrackerVeto) {
		NSLog(@"MenuCracker: Cooperation record missing controlling cracker veto call, can't load");
		return NO;
	}
	if (!(((*gSharedCooperationRecord)->suis_canLoadClass_Original &&
				(*gSharedCooperationRecord)->suis_canLoadClass_Cracked) &&
		  ((*gSharedCooperationRecord)->suiswriteMenuBarPlugins_Original &&
				(*gSharedCooperationRecord)->suiswriteMenuBarPlugins_Cracked) &&
		  // Only one of these will be patched at once
		  (((*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_Original &&
				(*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_Cracked) ||
		  ((*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_initExtra_Original &&
				(*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_initExtra_Cracked)))) {
		NSLog(@"MenuCracker: Cooperation record missing method implementations, can't load.");
		return NO;
	}

	// Decide if we think we're better.
	if (!SelfIsTheBetterVersion((*gSharedCooperationRecord)->controllingCrackerPath)) {
		// If we don't think we're better its likely because the cracker
		// currently in control is too new for us. Its already loaded, let
		// it deal with things.
		NSLog(@"MenuCracker: %@ (%@) deferring to %@ (%@).",
			  BundleVersionString(SelfBundle()),
			  SelfBundlePath(),
			  BundleVersionString([NSBundle bundleWithPath:(*gSharedCooperationRecord)->controllingCrackerPath]),
			  (*gSharedCooperationRecord)->controllingCrackerPath);
		return NO;
	}

	// Give the cracker currently in control a chance to veto us. Note that
	// in the future if there's some buggy veto function out there in an old
	// version we could check that here and refuse to accept the veto.
	// However, in general, we should assume the other instance is smarter
	// than us.
	if ((*(*gSharedCooperationRecord)->controllingCrackerVeto)(SelfBundlePath())) {
		NSLog(@"MenuCracker: %@ (%@) vetoed by %@ (%@).",
			  BundleVersionString(SelfBundle()),
			  SelfBundlePath(),
			  BundleVersionString([NSBundle bundleWithPath:(*gSharedCooperationRecord)->controllingCrackerPath]),
			  (*gSharedCooperationRecord)->controllingCrackerPath);
		return NO;
	}

	// We think we're better and we were not vetoed. Take over the
	// cooperation record. No new swizzles because the record version is the
	// same.
	NSLog(@"MenuCracker: %@ (%@) taking over from %@ (%@).",
		  BundleVersionString(SelfBundle()),
		  SelfBundlePath(),
		  BundleVersionString([NSBundle bundleWithPath:(*gSharedCooperationRecord)->controllingCrackerPath]),
		  (*gSharedCooperationRecord)->controllingCrackerPath);
	(*gSharedCooperationRecord)->version = kCrackerCooperationRecordVersion;
	[(*gSharedCooperationRecord)->controllingCrackerPath autorelease];
	(*gSharedCooperationRecord)->controllingCrackerPath = [SelfBundlePath() retain];
	(*gSharedCooperationRecord)->controllingCrackerVeto = &SelfIsTheBetterVersion;
	// 10.6 and earlier
	(*gSharedCooperationRecord)->suis_canLoadClass_Cracked = &CrackedSUIS_canLoadClass_;
	(*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_Cracked =
		&CrackedSUIScreateMenuExtra_atPosition_write_data_;
	(*gSharedCooperationRecord)->suiswriteMenuBarPlugins_Cracked = &CrackedSUISwriteMenuBarPlugins_;
	// 10.7
	(*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_initExtra_Cracked =
		&CrackedSUIScreateMenuExtra_atPosition_write_data_initExtra_;

	return YES;
}  // HandleSameRecordVersion

// Helper function for the case where the cooperation record version is older
// than us and we must take over
static BOOL HandleNewRecordVersion(Class suisClass) {
	// We are newer, take over the record. Allocate a new one.
	CrackerCooperationRecord *newCooperation = calloc(1, sizeof(CrackerCooperationRecord));
	if (!newCooperation) {
		NSLog(@"MenuCracker: Failed replacement record allocation, can't load.");
		return NO;
	}

	// Install new base record values
	newCooperation->version = kCrackerCooperationRecordVersion;
	newCooperation->controllingCrackerPath = [SelfBundlePath() retain];
	newCooperation->controllingCrackerVeto = &SelfIsTheBetterVersion;

	// Copy original function pointers
	switch ((*gSharedCooperationRecord)->version) {
		case 1:  // Copy version 1 record
			newCooperation->suis_canLoadClass_Original = (*gSharedCooperationRecord)->suis_canLoadClass_Original;
			newCooperation->suiscreateMenuExtra_atPosition_write_data_Original =
				(*gSharedCooperationRecord)->suiscreateMenuExtra_atPosition_write_data_Original;
			newCooperation->suiswriteMenuBarPlugins_Original = (*gSharedCooperationRecord)->suiswriteMenuBarPlugins_Original;
	}

	// Apply our new crack functions (in record order just for clarity)
	newCooperation->suis_canLoadClass_Cracked = &CrackedSUIS_canLoadClass_;
	newCooperation->suiscreateMenuExtra_atPosition_write_data_Cracked =
		&CrackedSUIScreateMenuExtra_atPosition_write_data_;
	newCooperation->suiswriteMenuBarPlugins_Cracked = &CrackedSUISwriteMenuBarPlugins_;
	newCooperation->suiscreateMenuExtra_atPosition_write_data_initExtra_Cracked =
		&CrackedSUIScreateMenuExtra_atPosition_write_data_initExtra_;

	// Swizzle additional methods not already patched by the cracker we are
	// taking over from. Note that the original cracker's swizzle's are	left in
	// place.
	switch ((*gSharedCooperationRecord)->version) {
		case 1:  // Swizzle version 2 and greater methods, but only where required
			if (ClassInstanceRespondsToSelector(suisClass, @selector(createMenuExtra:atPosition:write:data:initExtra:))) {
				if (!SimpleSwizzle(suisClass, @selector(createMenuExtra:atPosition:write:data:initExtra:),
								   (IMP)&RedirectSUIScreateMenuExtra_atPosition_write_data_initExtra_,
								   (IMP *)&(newCooperation->suiscreateMenuExtra_atPosition_write_data_initExtra_Original),
								   kSUIScreateMenuExtra_atPosition_write_data_initExtra_TypeSignature)) {
					NSLog(@"MenuCracker: Failed to swizzle -[SUISStartupObject createMenuExtra:atPosition:write:data:initExtra:], can't load.");
					goto unwindNewVersionRecord;
				}
			}
	}

	NSLog(@"MenuCracker: %@ (%@) new cooperation record taking over from %@ (%@).",
		  BundleVersionString(SelfBundle()),
		  SelfBundlePath(),
		  BundleVersionString([NSBundle bundleWithPath:(*gSharedCooperationRecord)->controllingCrackerPath]),
		  (*gSharedCooperationRecord)->controllingCrackerPath);
	// We could dealloc the old record here, but out of paranoid, we'll just
	// leak it and update the global.
	*gSharedCooperationRecord = newCooperation;

	return YES;

unwindNewVersionRecord:
	switch ((*gSharedCooperationRecord)->version) {
		case 1:  // Current active version is 1, we need to unwind version 2 swizzles
			if (newCooperation && newCooperation->suiscreateMenuExtra_atPosition_write_data_initExtra_Original) {
				SimpleSwizzle(suisClass, @selector(createMenuExtra:atPosition:write:data:initExtra:),
							  (IMP)newCooperation->suiscreateMenuExtra_atPosition_write_data_initExtra_Original,
							  NULL, kSUIScreateMenuExtra_atPosition_write_data_initExtra_TypeSignature);
			}
	}
	if (newCooperation) {
		free(newCooperation);
	}
	return NO;
}  // HandleNewRecordVersion

// Helper function for the very first load.
static BOOL HandleFirstLoad(Class suisClass) {
	// Alloc the global record (but don't install it yet)
	CrackerCooperationRecord *newCooperation = calloc(1, sizeof(CrackerCooperationRecord));
	if (!newCooperation) {
		NSLog(@"MenuCracker: Failed first load record allocation, can't load.");
		return NO;
	}

	// Fill out the record
	newCooperation->version = kCrackerCooperationRecordVersion;
	newCooperation->controllingCrackerPath = [SelfBundlePath() retain];
	newCooperation->controllingCrackerVeto = &SelfIsTheBetterVersion;
	newCooperation->suis_canLoadClass_Cracked = &CrackedSUIS_canLoadClass_;
	newCooperation->suiscreateMenuExtra_atPosition_write_data_Cracked =
		&CrackedSUIScreateMenuExtra_atPosition_write_data_;
	newCooperation->suiswriteMenuBarPlugins_Cracked = &CrackedSUISwriteMenuBarPlugins_;
	newCooperation->suiscreateMenuExtra_atPosition_write_data_initExtra_Cracked =
		&CrackedSUIScreateMenuExtra_atPosition_write_data_initExtra_;

	// Apply swizzles. If you haven't read the design notes at the top of the
	// file, resist temptation and DON'T HACK HERE. Please read the design
	// notes first.
	if (!SimpleSwizzle(suisClass, @selector(_canLoadClass:),
					   (IMP)&RedirectSUIS_canLoadClass_,
					   (IMP *)&(newCooperation->suis_canLoadClass_Original),
					   kSUIS_canLoadClass_TypeSignature)) {
		NSLog(@"MenuCracker: Failed to swizzle -[SUISStartupObject _canLoadClass:], can't load.");
		goto unwindFirstLoad;
	}
	if (ClassInstanceRespondsToSelector(suisClass, @selector(createMenuExtra:atPosition:write:data:))) {
		if (!SimpleSwizzle(suisClass, @selector(createMenuExtra:atPosition:write:data:),
						   (IMP)&RedirectSUIScreateMenuExtra_atPosition_write_data_,
						   (IMP *)&(newCooperation->suiscreateMenuExtra_atPosition_write_data_Original),
						   kSUIScreateMenuExtra_atPosition_write_data_TypeSignature)) {
			NSLog(@"MenuCracker: Failed to swizzle -[SUISStartupObject createMenuExtra:atPosition:write:data:], can't load.");
			goto unwindFirstLoad;
		}
	}
	if (!SimpleSwizzle(suisClass, @selector(writeMenuBarPlugins:),
					   (IMP)&RedirectSUISwriteMenuBarPlugins_,
					   (IMP *)&(newCooperation->suiswriteMenuBarPlugins_Original),
					   kSUISwriteMenuBarPlugins_TypeSignature)) {
		NSLog(@"MenuCracker: Failed to swizzle -[SUISStartupObject writeMenuBarPlugins:], can't load.");
		goto unwindFirstLoad;
	}
	if (ClassInstanceRespondsToSelector(suisClass, @selector(createMenuExtra:atPosition:write:data:initExtra:))) {
		if (!SimpleSwizzle(suisClass, @selector(createMenuExtra:atPosition:write:data:initExtra:),
						   (IMP)&RedirectSUIScreateMenuExtra_atPosition_write_data_initExtra_,
						   (IMP *)&(newCooperation->suiscreateMenuExtra_atPosition_write_data_initExtra_Original),
						   kSUIScreateMenuExtra_atPosition_write_data_initExtra_TypeSignature)) {
			NSLog(@"MenuCracker: Failed to swizzle -[SUISStartupObject createMenuExtra:atPosition:write:data:initExtra:], can't load.");
			goto unwindFirstLoad;
		}
	}

	// Now install the global record.
	*gSharedCooperationRecord = newCooperation;

	// No logging, let the LoadMenuCracker() message stand for us.
	// record
	return YES;

unwindFirstLoad:

	// Should not have been installed, but just to be safe
	if (*gSharedCooperationRecord && (*gSharedCooperationRecord == newCooperation)) {
		*gSharedCooperationRecord = NULL;
	}
	// Unswizzle anything installed
	if (newCooperation) {
		if (newCooperation->suis_canLoadClass_Original) {
			SimpleSwizzle(suisClass, @selector(_canLoadClass:),
						  (IMP)newCooperation->suis_canLoadClass_Original,
						  NULL, kSUIS_canLoadClass_TypeSignature);
		}
		// Won't be swizzled if suisClass doesn't respond to this when we checked above
		if (newCooperation->suiscreateMenuExtra_atPosition_write_data_Original) {
			SimpleSwizzle(suisClass, @selector(createMenuExtra:atPosition:write:data:),
						  (IMP)newCooperation->suiscreateMenuExtra_atPosition_write_data_Original,
						  NULL, kSUIScreateMenuExtra_atPosition_write_data_TypeSignature);
		}
		if (newCooperation->suiswriteMenuBarPlugins_Original) {
			SimpleSwizzle(suisClass, @selector(writeMenuBarPlugins:),
						  (IMP)newCooperation->suiswriteMenuBarPlugins_Original,
						  NULL, kSUISwriteMenuBarPlugins_TypeSignature);
		}
		// Again, won't be swizzled if suisClass didn't respond
		if (newCooperation->suiscreateMenuExtra_atPosition_write_data_initExtra_Original) {
			SimpleSwizzle(suisClass, @selector(createMenuExtra:atPosition:write:data:initExtra:),
						  (IMP)newCooperation->suiscreateMenuExtra_atPosition_write_data_initExtra_Original,
						  NULL, kSUIScreateMenuExtra_atPosition_write_data_initExtra_TypeSignature);
		}

		free(newCooperation);
	}
	return NO;

} // HandleFirstLoad


static void LoadMenuCracker(void) __attribute__((constructor));
static void LoadMenuCracker(void) {
	// Check SystemUIServer version. Realistically we won't see many pre-10.2
	// systems (and depending on future project/compiler upgrades we won't
	// load from ABI changes).
	NSString *suisVersionString = [[[NSBundle mainBundle] infoDictionary]
								   objectForKey:(NSString *)kCFBundleVersionKey];
	if (suisVersionString && ([suisVersionString floatValue] < 1.1)) {
		NSLog(@"MenuCracker: Only for Mac OS X 10.2 and later.");
		return;
	}

	// Used in setup and error cleanup, so get it now.
	Class suisClass = NSClassFromString(@"SUISStartupObject");
	if (!suisClass) {
		NSLog(@"MenuCracker: Can't find SUISStartupObject, can't load.");
		return;
	}

	// Find the cooperation record. MenuCrackerGlobalCooperationRecord is always
	// our local one, but we can look up the first one loaded (the one we will
	// share) and put it in a different variable.
	gSharedCooperationRecord = dlsym(RTLD_DEFAULT, "MenuCrackerGlobalCooperationRecord");
	if (!gSharedCooperationRecord) {
		NSLog(@"MenuCracker: Can't find shared cooperation record, can't load");
		return;
	}

	// Look at the cooperation pointer. If it exists some other instance of
	// the code is already running and we need to talk to it. No locking here
	// because SUIS is apparently single-threaded for menu extra loading.
	if (*gSharedCooperationRecord) {
		// Check record version and act accordingly
		if ((*gSharedCooperationRecord)->version > kCrackerCooperationRecordVersion) {
			NSLog(@"MenuCracker: %@ (%@) deferring to %@ (%@) based on record version %u.",
				  BundleVersionString(SelfBundle()),
				  SelfBundlePath(),
				  BundleVersionString([NSBundle bundleWithPath:(*gSharedCooperationRecord)->controllingCrackerPath]),
				  (*gSharedCooperationRecord)->controllingCrackerPath,
				  (*gSharedCooperationRecord)->version);
			return;
		} else if ((*gSharedCooperationRecord)->version == kCrackerCooperationRecordVersion) {
			if (!HandleSameRecordVersion(suisClass)) return;  // Helper will have logged failures
		} else {
			if (!HandleNewRecordVersion(suisClass)) return;  // Helper will have logged
		}
	} else {
		if (!HandleFirstLoad(suisClass)) return;  // Helper will have logged
	}

	// If we get here it was decided we're the best, either by virtue of
	// being the first to load or the best found so far. Either way, update
	// the SUIS preferences.
	WriteCrackedSUISPreferences();

    // Say it's me!
    /*NSLog(@"	MenuCracker %@ (%@)"
          @"\n	See http://sourceforge.net/projects/menucracker"
          @"\n	MenuCracker is now loaded. Ready to accept new menu extras.",
		  BundleVersionString(SelfBundle()),
		  SelfBundlePath());*/

	return;  // Successful load
} // LoadMenuCracker




