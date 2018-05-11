# MenuCracker
## **Now broken**, since 10.11 *El Capitan*. Since 10.12 *Sierra*, it is also completely useless, because the single difference between Apple's stock menu extras and custom ones was the ability to reorder them – which is now available to both.

##### Taken from : http://menucracker.cvs.sourceforge.net/
MenuCracker is a tool to re-enable the third-party menu extras that Apple has blocked since Mac OS X 10.2. Practically, it means that your StatusItem can now appear in the rightmost part of the status bar, be moved with CMD+click, just like stock Apple items.

## For end-users
* Copy MenuCracker.menu anywhere in your home directory (~/Applications or ~/Library/Bundles are relatively good choices).
* Then double click MenuCracker.menu. Nothing will appear in the menu bar, but you can now add third-party menu extras.

## For developers
If you are a developer and your menu extra is controlled by an application or preference pane there is some work for you to do. First add the MenuCracker binary to the resource folder of your application or preference pane. Then before calling CoreMenuExtraAddMenuExtra() for your menu extra execute the following code:
```
NSString *menuExtraPath = [[NSBundle mainBundle] pathForResource:@"MenuCracker" ofType:@"menu"];
CFURLRef url = CFURLCreateWithFileSystemPath(kCFAllocatorDefault, (CFStringRef)menuExtraPath, kCFURLPOSIXPathStyle, NO);

// Do not check the return value as it is always going to return an error
unsigned int outExtra;

CoreMenuExtraAddMenuExtra(url, 0, 0, nil, 0, &outExtra);
CFRelease(url);
```

## What if I have a problem ?
Trick question, I don't care about your problems.

## Nota Bene
As of June 2015, all of this repo's source code comes from http://menucracker.cvs.sourceforge.net/
The only I have done was to copy-paste (and slightly correct) the "Read Me" file to this README.MD file, and the "Artistic License" file to the GitHub-style LICENSE file.
Credits are given in the file's headers.
