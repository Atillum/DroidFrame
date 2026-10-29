#import <Cocoa/Cocoa.h>
#import <objc/runtime.h>
#import <QuartzCore/QuartzCore.h>

// SDL creates and positions its window before our sidebar is attached. Keep all
// backend window ordering private until the complete replacement is ready.
static BOOL RealmeWindowsReady = NO;
static NSUInteger RealmeSuppressedOrders = 0;
@interface NSWindow (RealmeStartupGate)
- (void)realme_orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)other;
@end
@implementation NSWindow (RealmeStartupGate)
- (void)realme_orderWindow:(NSWindowOrderingMode)place relativeTo:(NSInteger)other {
    self.animationBehavior = NSWindowAnimationBehaviorNone;
    if (!RealmeWindowsReady && place != NSWindowOut) { RealmeSuppressedOrders++; self.alphaValue = 0; return; }
    [self realme_orderWindow:place relativeTo:other];
}
@end

@interface RealmeSidebarDocument : NSView
@end
@implementation RealmeSidebarDocument
- (BOOL)isFlipped { return YES; }
@end

@interface DroidFrameToolbar : NSObject <NSWindowDelegate>
@property NSString *directory;
@property NSWindow *window;
@property NSWindow *screenWindow;
@property NSView *screenArea;
@property CGFloat aspect;
@property BOOL layingOut;
@property NSDate *attachedAt;
@property NSPopUpButton *device;
@property NSArray *lastDevices;
@property BOOL startupChecked;
@property NSString *lastGeometry;
@property BOOL ready;
@property NSView *compressionFooter;
@property NSButton *compressionClose;
@property NSLayoutConstraint *footerHeight;
@property NSLayoutConstraint *summaryHeight;
@property NSTextField *folderPath;
@property NSButton *record;
@property NSButton *shot;
@property NSTextField *timer;
@property NSTextField *status;
@property NSPopUpButton *quality;
@property NSPopUpButton *sound;
@property NSPopUpButton *compression;
@property NSButton *deleteOriginal;
@property NSProgressIndicator *compressionProgress;
@property NSTextField *compressionSummary;
@property NSStackView *compressionDetails;
@property NSMutableArray<NSTextField *> *detailFields;
@property NSMutableArray<NSLayoutConstraint *> *detailHeights;
@property BOOL attached;
@property NSString *lastFocus;
@end

@implementation DroidFrameToolbar
+ (void)load {
    NSString *directory = NSProcessInfo.processInfo.environment[@"REALME_STUDIO_IPC"];
    if (!directory) return;
    unsetenv("DYLD_INSERT_LIBRARIES");
    method_exchangeImplementations(class_getInstanceMethod(NSWindow.class,@selector(orderWindow:relativeTo:)),class_getInstanceMethod(NSWindow.class,@selector(realme_orderWindow:relativeTo:)));
    dispatch_async(dispatch_get_main_queue(), ^{
        static DroidFrameToolbar *toolbar;
        toolbar = [DroidFrameToolbar new]; toolbar.directory = directory;
        [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:YES block:^(NSTimer *timer) { [toolbar tick]; }];
    });
}
- (NSButton *)button:(NSString *)title command:(NSString *)command {
    NSButton *button = [NSButton buttonWithTitle:title target:self action:@selector(pressed:)];
    button.identifier = command;
    button.bezelStyle = NSBezelStyleRounded;
    return button;
}
- (void)send:(NSString *)action extra:(NSDictionary *)extra {
    NSMutableDictionary *message = [@{@"action":action, @"id":NSUUID.UUID.UUIDString} mutableCopy];
    if (extra) [message addEntriesFromDictionary:extra];
    NSData *bytes = [NSJSONSerialization dataWithJSONObject:message options:0 error:nil];
    NSString *filename = [NSString stringWithFormat:@"command.%020.0f.%@.json", NSDate.date.timeIntervalSince1970 * 1000000, message[@"id"]];
    [bytes writeToFile:[self.directory stringByAppendingPathComponent:filename] atomically:YES];
}
- (void)pressed:(NSButton *)sender { [self send:sender.identifier extra:nil]; }
- (void)selectDevice:(NSPopUpButton *)sender {
    NSString *serial = sender.selectedItem.representedObject;
    if (serial) [self send:@"device" extra:@{@"serial":serial}];
}
- (void)setting:(NSPopUpButton *)sender {
    [self send:@"settings" extra:@{@"quality":@(self.quality.indexOfSelectedItem), @"sound":@(self.sound.indexOfSelectedItem), @"compression":@(self.compression.indexOfSelectedItem), @"deleteOriginal":@(self.deleteOriginal.state == NSControlStateValueOn)}];
}
- (NSTextField *)label:(NSString *)text size:(CGFloat)size color:(NSColor *)color {
    NSTextField *field = [NSTextField labelWithString:text];
    field.font = [NSFont systemFontOfSize:size]; field.textColor = color; return field;
}
- (NSStackView *)row:(NSArray *)views {
    NSStackView *stack = [NSStackView stackViewWithViews:views]; stack.spacing = 10; return stack;
}
- (NSSize)fittedContentSize:(NSSize)proposed {
    NSRect available = (self.window.screen ?: NSScreen.mainScreen).visibleFrame;
    CGFloat chrome = self.window.frame.size.height - self.window.contentView.frame.size.height;
    CGFloat height = MAX(350, proposed.height);
    height = MIN(height, MAX(350, available.size.height - chrome));
    height = MIN(height, MAX(350, (available.size.width - 340)/self.aspect));
    return NSMakeSize(340 + round(height*self.aspect), round(height));
}
- (NSSize)windowWillResize:(NSWindow *)sender toSize:(NSSize)frameSize {
    NSRect content = [sender contentRectForFrameRect:NSMakeRect(0, 0, frameSize.width, frameSize.height)];
    NSSize old = sender.contentView.bounds.size;
    if (fabs(content.size.width-old.width) > fabs(content.size.height-old.height)*self.aspect) {
        content.size.height = (content.size.width-340)/self.aspect;
    }
    content.size = [self fittedContentSize:content.size];
    return [sender frameRectForContentRect:content].size;
}
- (void)layoutScreen {
    if (self.layingOut || !self.screenWindow || !self.screenArea) return;
    self.layingOut = YES;
    NSSize target = [self fittedContentSize:self.window.contentView.bounds.size];
    if (fabs(self.window.contentView.bounds.size.width-target.width) > 0.5 || fabs(self.window.contentView.bounds.size.height-target.height) > 0.5) {
        [self.window setContentSize:target];
    }
    self.window.contentView.needsLayout = YES;
    [self.window.contentView layoutSubtreeIfNeeded];
    NSRect area = [self.screenArea convertRect:self.screenArea.bounds toView:nil];
    area = [self.window convertRectToScreen:area];
    NSRect frame = NSMakeRect(round(area.origin.x), round(area.origin.y), round(area.size.width), round(area.size.height));
    if (!NSEqualRects(frame, self.screenWindow.frame)) [self.screenWindow setFrame:frame display:YES];
    // This mask affects the local Metal preview only. The encoded stream and
    // ADB screenshots never pass through this view.
    CALayer *previewLayer = self.screenWindow.contentView.layer;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    previewLayer.cornerRadius = 12;
    previewLayer.maskedCorners = previewLayer.geometryFlipped ? kCALayerMaxXMaxYCorner : kCALayerMaxXMinYCorner;
    previewLayer.masksToBounds = YES;
    [CATransaction commit];
    self.layingOut = NO;
    NSString *geometry = NSStringFromRect(self.window.frame);
    if (![geometry isEqual:self.lastGeometry]) {
        [geometry writeToFile:[self.directory stringByAppendingPathComponent:@"geometry.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        self.lastGeometry = geometry;
    }
    // SDL finishes positioning its native surface after creation. Reconcile on
    // each run-loop tick and reveal it only after the initial positioning settles.
    if (self.window.visible && -self.attachedAt.timeIntervalSinceNow >= 1.0) self.screenWindow.alphaValue = 1;
}
- (void)windowDidResize:(NSNotification *)notification { [self.window.contentView layoutSubtreeIfNeeded]; [self layoutScreen]; }
- (void)windowDidMove:(NSNotification *)notification { [self layoutScreen]; }
- (BOOL)windowShouldClose:(NSWindow *)sender { [self send:@"quit" extra:nil]; return NO; }
- (void)attach:(NSWindow *)screen {
    NSString *savedGeometry = [NSString stringWithContentsOfFile:[self.directory stringByAppendingPathComponent:@"geometry.txt"] encoding:NSUTF8StringEncoding error:nil];
    self.screenWindow = screen; self.attached = YES; self.attachedAt = NSDate.date;
    self.aspect = [NSProcessInfo.processInfo.environment[@"REALME_STUDIO_ASPECT"] doubleValue];
    if (self.aspect < 0.1 || self.aspect > 10) self.aspect = screen.contentView.bounds.size.width / MAX(1, screen.contentView.bounds.size.height);
    screen.alphaValue = 0;
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    // Preserve SDL's own view and event coordinates; attach its borderless
    // rendering surface inside the right side of a single outer frame.
    screen.styleMask = NSWindowStyleMaskBorderless;
    screen.opaque = NO; screen.backgroundColor = NSColor.clearColor;
    screen.contentView.wantsLayer = YES;
    screen.hasShadow = NO; screen.movable = NO; screen.title = @"DroidFrame rendering surface";
    screen.collectionBehavior = NSWindowCollectionBehaviorFullScreenAuxiliary;
    NSWindow *outer = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 740, 740)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window = outer; outer.delegate = self; outer.releasedWhenClosed = NO;
    outer.title = @"DroidFrame"; outer.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    outer.minSize = NSMakeSize(400, 370);
    [outer setContentSize:[self fittedContentSize:NSMakeSize(740, 740)]];
    [outer center];
    if (savedGeometry) [outer setFrame:NSRectFromString(savedGeometry) display:NO];
    outer.contentView.wantsLayer = YES; outer.contentView.layer.backgroundColor = NSColor.blackColor.CGColor;
    NSView *sidebar = [[NSView alloc] init]; sidebar.translatesAutoresizingMaskIntoConstraints = NO;
    sidebar.wantsLayer = YES; sidebar.layer.backgroundColor = [NSColor colorWithWhite:0.12 alpha:1].CGColor;
    self.screenArea = [[NSView alloc] init]; self.screenArea.translatesAutoresizingMaskIntoConstraints = NO;
    [outer.contentView addSubview:sidebar]; [outer.contentView addSubview:self.screenArea];
    [NSLayoutConstraint activateConstraints:@[
        [sidebar.leadingAnchor constraintEqualToAnchor:outer.contentView.leadingAnchor],
        [sidebar.topAnchor constraintEqualToAnchor:outer.contentView.topAnchor],
        [sidebar.bottomAnchor constraintEqualToAnchor:outer.contentView.bottomAnchor],
        [sidebar.widthAnchor constraintEqualToConstant:340],
        [self.screenArea.leadingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [self.screenArea.trailingAnchor constraintEqualToAnchor:outer.contentView.trailingAnchor],
        [self.screenArea.topAnchor constraintEqualToAnchor:outer.contentView.topAnchor],
        [self.screenArea.bottomAnchor constraintEqualToAnchor:outer.contentView.bottomAnchor]
    ]];
    self.record = [self button:@"● Начать запись" command:@"record"];
    self.record.contentTintColor = NSColor.systemRedColor;
    self.record.controlSize = NSControlSizeRegular; self.record.font = [NSFont systemFontOfSize:13];
    self.record.keyEquivalent = @"r"; self.record.keyEquivalentModifierMask = NSEventModifierFlagCommand;
    self.shot = [self button:@"Скриншот" command:@"screenshot"];
    self.shot.keyEquivalent = @"s"; self.shot.keyEquivalentModifierMask = NSEventModifierFlagCommand | NSEventModifierFlagShift;
    self.timer = [NSTextField labelWithString:@"00:00:00"];
    self.timer.font = [NSFont monospacedDigitSystemFontOfSize:38 weight:NSFontWeightLight];
    self.quality = [[NSPopUpButton alloc] init]; [self.quality addItemsWithTitles:@[@"720p · экономно", @"1080p · чётче", @"Исходное разрешение"]];
    self.quality.target = self; self.quality.action = @selector(setting:);
    self.sound = [[NSPopUpButton alloc] init]; [self.sound addItemsWithTitles:@[@"Звук телефона", @"Микрофон", @"Без звука"]];
    self.sound.target = self; self.sound.action = @selector(setting:);
    self.compression = [[NSPopUpButton alloc] init]; [self.compression addItemsWithTitles:@[@"Без доп. сжатия", @"Компактное видео"]];
    self.compression.target = self; self.compression.action = @selector(setting:);
    self.deleteOriginal = [NSButton checkboxWithTitle:@"Удалять исходник после проверки" target:self action:@selector(setting:)];
    self.deleteOriginal.font = [NSFont systemFontOfSize:11];
    self.compressionProgress = [[NSProgressIndicator alloc] init]; self.compressionProgress.indeterminate = NO;
    self.compressionProgress.style = NSProgressIndicatorStyleBar;
    [self.compressionProgress.heightAnchor constraintEqualToConstant:6].active = YES;
    self.compressionProgress.minValue = 0; self.compressionProgress.maxValue = 100;
    [self.compressionProgress.widthAnchor constraintEqualToConstant:292].active = YES;
    self.compressionSummary = [NSTextField wrappingLabelWithString:@""];
    self.compressionSummary.font = [NSFont systemFontOfSize:11]; self.compressionSummary.textColor = NSColor.secondaryLabelColor;
    [self.compressionSummary.widthAnchor constraintEqualToConstant:272].active = YES;
    self.summaryHeight = [self.compressionSummary.heightAnchor constraintEqualToConstant:18];
    self.status = [NSTextField wrappingLabelWithString:@"Подключение…"];
    self.status.font = [NSFont systemFontOfSize:12]; self.status.textColor = NSColor.systemTealColor;
    self.device = [[NSPopUpButton alloc] init]; self.device.target = self; self.device.action = @selector(selectDevice:);
    [self.device.widthAnchor constraintEqualToConstant:292].active = YES;
    self.folderPath = [NSTextField wrappingLabelWithString:@""];
    self.folderPath.font = [NSFont systemFontOfSize:11]; self.folderPath.textColor = NSColor.secondaryLabelColor;
    self.folderPath.maximumNumberOfLines = 2;
    [self.folderPath.widthAnchor constraintEqualToConstant:292].active = YES;
    NSStackView *stack = [NSStackView stackViewWithViews:@[
        [self label:@"DROIDFRAME" size:21 color:NSColor.labelColor],
        [self label:@"Экран телефона. Всё под рукой." size:12 color:NSColor.secondaryLabelColor],
        self.device, self.status, self.timer,
        [self label:@"Без ограничения длительности" size:11 color:NSColor.secondaryLabelColor],
        self.record, self.shot,
        [self row:@[[self label:@"Качество" size:12 color:NSColor.secondaryLabelColor], self.quality]],
        [self row:@[[self label:@"Сжатие" size:12 color:NSColor.secondaryLabelColor], self.compression]],
        self.deleteOriginal,
        [self row:@[[self label:@"Аудио" size:12 color:NSColor.secondaryLabelColor], self.sound]],
        [self button:@"Выбрать папку сохранения…" command:@"folder"],
        [self button:@"Открыть папку сохранения" command:@"files"],
        self.folderPath,
        [self button:@"Показать последний файл" command:@"last"],
        [self label:@"Скриншоты доступны во время записи." size:10 color:NSColor.secondaryLabelColor]
    ]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical; stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = NO;
    self.compressionFooter = [[NSView alloc] init]; self.compressionFooter.translatesAutoresizingMaskIntoConstraints = NO;
    self.compressionFooter.wantsLayer = YES; self.compressionFooter.layer.backgroundColor = [NSColor colorWithWhite:0.16 alpha:1].CGColor;
    [sidebar addSubview:self.compressionFooter];
    self.footerHeight = [self.compressionFooter.heightAnchor constraintEqualToConstant:0];
    [NSLayoutConstraint activateConstraints:@[
        [self.compressionFooter.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
        [self.compressionFooter.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [self.compressionFooter.bottomAnchor constraintEqualToAnchor:sidebar.bottomAnchor], self.footerHeight
    ]];
    self.compressionDetails = [NSStackView new]; self.compressionDetails.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.compressionDetails.alignment = NSLayoutAttributeLeading; self.compressionDetails.spacing = 6;
    self.detailFields = [NSMutableArray new]; self.detailHeights = [NSMutableArray new];
    for (NSInteger index = 0; index < 4; index++) {
        if (index > 0) {
            NSBox *line = [NSBox new]; line.boxType = NSBoxSeparator;
            [line.widthAnchor constraintEqualToConstant:272].active = YES; [line.heightAnchor constraintEqualToConstant:1].active = YES;
            [self.compressionDetails addArrangedSubview:line];
        }
        NSTextField *field = [NSTextField wrappingLabelWithString:@""];
        [field.widthAnchor constraintEqualToConstant:272].active = YES;
        NSLayoutConstraint *height = [field.heightAnchor constraintEqualToConstant:18]; height.active = YES;
        [self.detailFields addObject:field]; [self.detailHeights addObject:height];
        [self.compressionDetails addArrangedSubview:field];
    }
    NSStackView *footerStack = [NSStackView stackViewWithViews:@[self.compressionSummary,self.compressionDetails,self.compressionProgress]];
    footerStack.orientation = NSUserInterfaceLayoutOrientationVertical; footerStack.alignment = NSLayoutAttributeLeading;
    footerStack.spacing = 10; footerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.compressionFooter addSubview:footerStack];
    self.compressionClose = [NSButton buttonWithTitle:@"×" target:self action:@selector(pressed:)];
    self.compressionClose.identifier = @"dismissCompression"; self.compressionClose.bordered = NO;
    self.compressionClose.toolTip = @"Скрыть панель сжатия";
    [self.compressionClose setAccessibilityLabel:@"Скрыть панель сжатия"];
    self.compressionClose.translatesAutoresizingMaskIntoConstraints = NO;
    [self.compressionFooter addSubview:self.compressionClose];
    [NSLayoutConstraint activateConstraints:@[
        [self.compressionClose.topAnchor constraintEqualToAnchor:self.compressionFooter.topAnchor constant:3],
        [self.compressionClose.trailingAnchor constraintEqualToAnchor:self.compressionFooter.trailingAnchor constant:-4],
        [self.compressionClose.widthAnchor constraintEqualToConstant:20], [self.compressionClose.heightAnchor constraintEqualToConstant:20]]];
    [NSLayoutConstraint activateConstraints:@[
        [footerStack.leadingAnchor constraintEqualToAnchor:self.compressionFooter.leadingAnchor constant:24],
        [footerStack.trailingAnchor constraintEqualToAnchor:self.compressionFooter.trailingAnchor constant:-24],
        [footerStack.topAnchor constraintEqualToAnchor:self.compressionFooter.topAnchor constant:12],
        self.summaryHeight
    ]];
    NSScrollView *scroll = [[NSScrollView alloc] init]; scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES; scroll.autohidesScrollers = YES; scroll.drawsBackground = NO;
    [sidebar addSubview:scroll];
    [NSLayoutConstraint activateConstraints:@[
        [scroll.leadingAnchor constraintEqualToAnchor:sidebar.leadingAnchor],
        [scroll.trailingAnchor constraintEqualToAnchor:sidebar.trailingAnchor],
        [scroll.topAnchor constraintEqualToAnchor:sidebar.topAnchor],
        [scroll.bottomAnchor constraintEqualToAnchor:self.compressionFooter.topAnchor]
    ]];
    RealmeSidebarDocument *document = [[RealmeSidebarDocument alloc] initWithFrame:NSMakeRect(0,0,340,800)];
    document.autoresizingMask = NSViewWidthSizable; scroll.documentView = document;
    [document addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:document.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:document.trailingAnchor constant:-24],
        [stack.topAnchor constraintEqualToAnchor:document.topAnchor constant:28],
        [self.record.widthAnchor constraintEqualToConstant:292],
        [self.shot.widthAnchor constraintEqualToConstant:292],
        [self.status.widthAnchor constraintEqualToConstant:292],
        [self.status.heightAnchor constraintEqualToConstant:46]
    ]];
    self.shot.controlSize = NSControlSizeRegular; self.shot.font = [NSFont systemFontOfSize:13];
    [self.record.heightAnchor constraintEqualToConstant:24].active = YES;
    [self.shot.heightAnchor constraintEqualToConstant:24].active = YES;
    [outer.contentView layoutSubtreeIfNeeded];
    [outer addChildWindow:screen ordered:NSWindowAbove];
    [self layoutScreen];
    [NSNotificationCenter.defaultCenter addObserverForName:NSWindowDidResizeNotification object:screen queue:nil usingBlock:^(NSNotification *note) {
        if (!self.layingOut && -self.attachedAt.timeIntervalSinceNow > 2) {
            NSSize size = screen.contentView.bounds.size;
            CGFloat changed = size.width/MAX(1,size.height);
            if (changed > 0.1 && changed < 10 && fabs(changed-self.aspect)>0.01) self.aspect = changed;
            [self layoutScreen];
        }
    }];
    NSDictionary *metrics = @{@"attached":@YES, @"window":@(outer.windowNumber), @"pid":@(NSProcessInfo.processInfo.processIdentifier)};
    [[NSJSONSerialization dataWithJSONObject:metrics options:0 error:nil] writeToFile:[self.directory stringByAppendingPathComponent:@"toolbar.json"] atomically:YES];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        self.ready = YES; [self layoutScreen];
        if (NSProcessInfo.processInfo.environment[@"REALME_STUDIO_TEST"]) {
            NSUInteger visible = 0;
            for (NSWindow *window in NSApp.windows) if (window.visible && window.alphaValue > 0) visible++;
            NSDictionary *gate = @{@"suppressedOrders":@(RealmeSuppressedOrders),@"visibleBeforeReady":@(visible),@"frame":NSStringFromRect(outer.frame)};
            [[NSJSONSerialization dataWithJSONObject:gate options:0 error:nil] writeToFile:[self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"startup-gate-%d.json",NSProcessInfo.processInfo.processIdentifier]] atomically:YES];
        }
        RealmeWindowsReady = YES;
        outer.alphaValue = 1; screen.alphaValue = 1;
        [outer makeKeyAndOrderFront:nil]; [screen orderWindow:NSWindowAbove relativeTo:outer.windowNumber]; [NSApp activateIgnoringOtherApps:YES];
        [self send:@"ready" extra:nil];
    });
}
- (void)tick {
    if (!self.attached) {
        for (NSWindow *window in NSApp.windows) {
            if ([window.title hasPrefix:@"DroidFrame"]) { [self attach:window]; break; }
        }
    }
    if (!self.attached) return;
    [self layoutScreen];
    NSData *bytes = [NSData dataWithContentsOfFile:[self.directory stringByAppendingPathComponent:@"state.json"]];
    NSDictionary *state = bytes ? [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil] : nil;
    if (!state) return;
    if (NSProcessInfo.processInfo.environment[@"REALME_STUDIO_TEST"]) {
        NSDictionary *metrics = @{
            @"topLevelWindows":@([[NSApp.windows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSWindow *window, NSDictionary *bindings) { return window.visible && !window.parentWindow; }]] count]),
            @"attachedSurfaces":@(self.window.childWindows.count),
            @"borderlessScreen":@(self.screenWindow.styleMask == NSWindowStyleMaskBorderless),
            @"screenWidth":@(self.screenWindow.contentView.bounds.size.width),
            @"screenHeight":@(self.screenWindow.contentView.bounds.size.height),
            @"expectedAspect":@(self.aspect),
            @"outerWidth":@(self.window.contentView.bounds.size.width),
            @"outerHeight":@(self.window.contentView.bounds.size.height),
            @"actualFrame":NSStringFromRect(self.screenWindow.frame),
            @"expectedFrame":NSStringFromRect([self.window convertRectToScreen:[self.screenArea convertRect:self.screenArea.bounds toView:nil]]),
            @"sideGap":@(fabs(self.screenArea.bounds.size.width-self.screenWindow.contentView.bounds.size.width)),
            @"surfaceAlpha":@(self.screenWindow.alphaValue),
            @"pid":@(NSProcessInfo.processInfo.processIdentifier)
        };
        NSData *diagnostics = [NSJSONSerialization dataWithJSONObject:metrics options:0 error:nil];
        [diagnostics writeToFile:[self.directory stringByAppendingPathComponent:@"diagnostics.json"] atomically:YES];
        if (!self.startupChecked && self.screenWindow.alphaValue == 1) {
            self.startupChecked = YES;
            [diagnostics writeToFile:[self.directory stringByAppendingPathComponent:@"startup.json"] atomically:YES];
            [diagnostics writeToFile:[self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"startup-%d.json", NSProcessInfo.processInfo.processIdentifier]] atomically:YES];
        }
    }
    NSArray *devices = state[@"devices"] ?: @[];
    if (![devices isEqual:self.lastDevices]) {
        self.lastDevices = devices; [self.device removeAllItems];
        for (NSDictionary *device in devices) {
            [self.device addItemWithTitle:device[@"name"]]; self.device.lastItem.representedObject = device[@"serial"];
        }
    }
    for (NSMenuItem *item in self.device.itemArray) if ([item.representedObject isEqual:state[@"selectedDevice"]]) [self.device selectItem:item];
    BOOL recording = [state[@"recording"] boolValue];
    self.device.enabled = !recording && ![state[@"switching"] boolValue] && devices.count > 1;
    self.record.title = recording ? @"■ Стоп и сохранить" : @"● Начать запись";
    self.record.enabled = ![state[@"switching"] boolValue];
    self.shot.enabled = ![state[@"screenshotBusy"] boolValue];
    self.quality.enabled = !recording; self.sound.enabled = !recording;
    self.compression.enabled = !recording;
    if (!self.compression.isHighlighted) [self.compression selectItemAtIndex:[state[@"compression"] integerValue]];
    self.deleteOriginal.state = [state[@"deleteOriginal"] boolValue] ? NSControlStateValueOn : NSControlStateValueOff;
    self.deleteOriginal.enabled = !recording && self.compression.indexOfSelectedItem == 1;
    self.deleteOriginal.hidden = self.compression.indexOfSelectedItem == 0;
    BOOL compressing = [state[@"compressing"] boolValue];
    BOOL showCompression = [state[@"compressionVisible"] boolValue];
    self.compressionFooter.hidden = !showCompression; self.footerHeight.constant = 0;
    self.compressionProgress.hidden = NO;
    self.compressionProgress.doubleValue = [state[@"compressionProgress"] doubleValue];
    NSString *compressionText = state[@"compressionSummary"];
    if (!compressionText.length) compressionText = @"";
    self.compressionSummary.stringValue = compressionText;
    NSRect textBounds = [compressionText boundingRectWithSize:NSMakeSize(262,CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading attributes:@{NSFontAttributeName:self.compressionSummary.font}];
    CGFloat cellHeight = [self.compressionSummary.cell cellSizeForBounds:NSMakeRect(0,0,272,CGFLOAT_MAX)].height;
    self.summaryHeight.constant = MAX(18,ceil(MAX(textBounds.size.height,cellHeight))+8);
    self.footerHeight.constant = showCompression ? self.summaryHeight.constant + 50 : 0;
    self.compressionSummary.toolTip = state[@"compressionResultPath"];
    NSDictionary *details = state[@"compressionDetails"];
    BOOL detailed = details.count > 0;
    self.compressionSummary.hidden = detailed; self.compressionDetails.hidden = !detailed;
    CGFloat detailsHeight = 39;
    NSArray *keys = @[@"title",@"file",@"folder",@"size"], *prefixes = @[@"",@"Файл: ",@"Папка: ",@"Размер: "];
    for (NSInteger index = 0; index < 4; index++) {
        NSString *prefix = prefixes[index]; NSString *text = [prefix stringByAppendingString:details[keys[index]] ?: @""];
        NSMutableParagraphStyle *paragraph = [NSMutableParagraphStyle new]; paragraph.lineBreakMode = NSLineBreakByCharWrapping;
        NSMutableAttributedString *value = [[NSMutableAttributedString alloc] initWithString:text attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:11],NSForegroundColorAttributeName:NSColor.secondaryLabelColor,NSParagraphStyleAttributeName:paragraph}];
        [value addAttribute:NSFontAttributeName value:[NSFont boldSystemFontOfSize:11] range:NSMakeRange(0,index == 0 ? text.length : prefix.length)];
        NSTextField *field = self.detailFields[index]; field.attributedStringValue = value; field.toolTip = text;
        NSRect bounds = [value boundingRectWithSize:NSMakeSize(262,CGFLOAT_MAX) options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingUsesFontLeading];
        CGFloat cell = [field.cell cellSizeForBounds:NSMakeRect(0,0,272,CGFLOAT_MAX)].height;
        self.detailHeights[index].constant = MAX(18,ceil(MAX(bounds.size.height,cell))+8);
        detailsHeight += self.detailHeights[index].constant;
    }
    self.footerHeight.constant = showCompression ? (detailed ? detailsHeight : self.summaryHeight.constant)+50 : 0;
    self.folderPath.stringValue = [@"Сохранение: " stringByAppendingString:(state[@"folderDisplay"] ?: @"")];
    self.folderPath.toolTip = state[@"folderPath"];
    if (!self.quality.isHighlighted) [self.quality selectItemAtIndex:[state[@"quality"] integerValue]];
    if (!self.sound.isHighlighted) [self.sound selectItemAtIndex:[state[@"sound"] integerValue]];
    self.timer.stringValue = state[@"time"] ?: @"00:00:00";
    self.status.stringValue = state[@"status"] ?: @"";
    NSString *focus = state[@"focus"];
    if (NSProcessInfo.processInfo.environment[@"REALME_STUDIO_TEST"]) {
        NSDictionary *buttons = @{@"recordWidth":@(self.record.frame.size.width),@"recordHeight":@(self.record.frame.size.height),@"shotWidth":@(self.shot.frame.size.width),@"shotHeight":@(self.shot.frame.size.height),@"recordStyle":@(self.record.bezelStyle),@"shotStyle":@(self.shot.bezelStyle),@"recordSize":@(self.record.controlSize),@"shotSize":@(self.shot.controlSize)};
        NSString *buttonPhase = [state[@"switching"] boolValue] ? @"switching" : recording ? @"recording" : @"preview";
        [[NSJSONSerialization dataWithJSONObject:buttons options:0 error:nil] writeToFile:[self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"buttons-%@.json",buttonPhase]] atomically:YES];
        NSString *phase = !showCompression && [state[@"compressionProgress"] doubleValue] >= 100 ? @"expired" : compressing ? @"busy" : recording ? @"recording" : [state[@"compressionProgress"] doubleValue] >= 100 ? @"done" : @"idle";
        NSDictionary *footerState = @{@"visible":@(showCompression), @"height":@(self.footerHeight.constant), @"barHeight":@(self.compressionProgress.frame.size.height), @"progress":@(self.compressionProgress.doubleValue), @"text":self.compressionSummary.stringValue, @"folder":self.folderPath.stringValue};
        if (showCompression && !compressing) {
            NSView *sidebar = self.compressionFooter.superview;
            NSString *preview = [self.directory stringByAppendingPathComponent:@"sidebar-result.png"];
            if (![[NSFileManager defaultManager] fileExistsAtPath:preview]) {
                [sidebar layoutSubtreeIfNeeded];
                NSBitmapImageRep *bitmap = [sidebar bitmapImageRepForCachingDisplayInRect:sidebar.bounds];
                [sidebar cacheDisplayInRect:sidebar.bounds toBitmapImageRep:bitmap];
                [[bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:preview atomically:YES];
            }
        }
        [[NSJSONSerialization dataWithJSONObject:footerState options:0 error:nil] writeToFile:[self.directory stringByAppendingPathComponent:[NSString stringWithFormat:@"footer-%@.json",phase]] atomically:YES];
    }
    if (self.ready && focus && ![focus isEqual:self.lastFocus]) { self.lastFocus = focus; [self.window makeKeyAndOrderFront:nil]; [NSApp activateIgnoringOtherApps:YES]; }
    NSString *testAction = state[@"smokeClick"];
    NSString *marker = [self.directory stringByAppendingPathComponent:[@"clicked-" stringByAppendingString:testAction ?: @""]];
    BOOL testReady = ![state[@"switching"] boolValue] &&
        (([testAction isEqual:@"dismissCompression"] && showCompression && !compressing) ||
         ([testAction isEqual:@"record"] && !recording && self.record.enabled) ||
         ([testAction isEqual:@"stop"] && recording && self.record.enabled) ||
         ([testAction isEqual:@"close"] && recording && self.record.enabled) ||
         ([testAction isEqual:@"screenshot"] && recording && self.shot.enabled));
    if (testReady && ![[NSFileManager defaultManager] fileExistsAtPath:marker]) {
        [@"done" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:nil];
        if ([testAction isEqual:@"dismissCompression"]) [self.compressionClose performClick:nil];
        else if ([testAction isEqual:@"screenshot"]) [self.shot performClick:nil];
        else if ([testAction isEqual:@"close"]) [self.window performClose:nil];
        else [self.record performClick:nil];
        if ([testAction isEqual:@"screenshot"]) {
            [self.window setContentSize:NSMakeSize(820, 700)];
            [self.window.contentView layoutSubtreeIfNeeded]; [self layoutScreen];
            NSDictionary *geometry = @{@"width":@(self.screenWindow.contentView.bounds.size.width), @"height":@(self.screenWindow.contentView.bounds.size.height), @"aspect":@(self.aspect)};
            [[NSJSONSerialization dataWithJSONObject:geometry options:0 error:nil] writeToFile:[self.directory stringByAppendingPathComponent:@"resized.json"] atomically:YES];
            [self.window setContentSize:NSMakeSize(740, 740)];
            [self.window.contentView layoutSubtreeIfNeeded]; [self layoutScreen];
        }
    }
}
@end
