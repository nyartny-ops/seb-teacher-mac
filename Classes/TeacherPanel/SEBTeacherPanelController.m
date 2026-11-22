//
//  SEBTeacherPanelController.m
//  Safe Exam Browser — Teacher Panel
//

#import "SEBTeacherPanelController.h"
#import "SEBTeacherSettings.h"

typedef NS_ENUM(NSInteger, SEBTeacherPendingAction) {
    SEBTeacherPendingActionNone = 0,
    SEBTeacherPendingActionOpenSettings,
    SEBTeacherPendingActionStart
};

static const NSInteger SEBTeacherMaxPasswordAttempts = 5;
static const NSTimeInterval SEBTeacherLockoutSeconds = 30;
static const CGFloat SEBTeacherWindowWidth = 620;


@interface SEBTeacherFlippedView : NSView
@end

@implementation SEBTeacherFlippedView
- (BOOL)isFlipped { return YES; }
@end


@interface SEBTeacherPanelController ()

@property (nonatomic, copy, nullable) void (^completion)(BOOL startExam);

// Стартовый экран
@property (nonatomic, strong) NSView *startView;
@property (nonatomic, strong) NSTextField *levelLabel;
@property (nonatomic, strong) NSTextField *urlLabel;
@property (nonatomic, strong) NSStackView *mainButtons;
@property (nonatomic, strong) NSStackView *passwordBox;
@property (nonatomic, strong) NSTextField *passwordPrompt;
@property (nonatomic, strong) NSSecureTextField *passwordField;
@property (nonatomic, strong) NSTextField *passwordError;
@property (nonatomic, strong) NSButton *passwordOKButton;
@property (nonatomic) SEBTeacherPendingAction pendingAction;
@property (nonatomic) NSInteger failedAttempts;
@property (nonatomic, strong, nullable) NSDate *lockedUntil;

// Экран настроек
@property (nonatomic, strong) NSView *settingsView;
@property (nonatomic, strong) NSSegmentedControl *presetControl;
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSButton *> *checkboxes;
@property (nonatomic, strong) NSPopUpButton *quitPasswordPopup;
@property (nonatomic, strong) NSSecureTextField *customQuitPasswordField;
@property (nonatomic, strong) NSButton *requirePasswordToStartCheckbox;
@property (nonatomic, strong) NSTextField *startURLField;
@property (nonatomic, strong) NSScrollView *settingsScrollView;

@end


@implementation SEBTeacherPanelController

+ (instancetype)sharedController
{
    static SEBTeacherPanelController *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [[SEBTeacherPanelController alloc] init];
    });
    return shared;
}

- (instancetype)init
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, SEBTeacherWindowWidth, 440)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Safe Exam Browser — панель преподавателя";
    window.releasedWhenClosed = NO;
    window.level = NSModalPanelWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    self = [super initWithWindow:window];
    if (self) {
        window.delegate = self;
        _checkboxes = [NSMutableDictionary new];
        [self buildStartView];
        [self buildSettingsView];
    }
    return self;
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    return NO;
}


#pragma mark - Показ

- (void)showWithCompletion:(void (^)(BOOL startExam))completion
{
    self.completion = completion;
    [[SEBTeacherSettings sharedSettings] reload];
    [self showStartView];
    [self.window center];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:self];
    [self conditionallyRunAutotest];
}

// Automated UI check for the CI build: only runs if the environment variable
// SEB_TEACHER_AUTOTEST_PASSWORD contains the correct teacher password, so it can't be
// used to bypass the password. Walks through the panel and writes marker files to
// /tmp/seb-autotest/ so the CI can take a screenshot of each stage.
- (void)autotestMark:(NSString *)stage
{
    NSString *directory = @"/tmp/seb-autotest";
    [[NSFileManager defaultManager] createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    [[NSData data] writeToFile:[directory stringByAppendingPathComponent:stage] atomically:YES];
    NSLog(@"[TeacherPanel] Autotest stage: %@", stage);
}

- (void)autotestAfter:(NSTimeInterval)seconds do:(dispatch_block_t)block
{
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

- (void)conditionallyRunAutotest
{
    static BOOL autotestStarted = NO;
    NSString *password = [NSProcessInfo processInfo].environment[@"SEB_TEACHER_AUTOTEST_PASSWORD"];
    if (autotestStarted || password.length == 0 ||
        ![[SEBTeacherSettings sharedSettings] checkTeacherPassword:password]) {
        return;
    }
    autotestStarted = YES;
    [self autotestAfter:2 do:^{ [self autotestMark:@"1-panel"]; }];
    [self autotestAfter:4 do:^{
        if (!self.completion) return;
        [self showSettingsView];
        [self autotestAfter:1.5 do:^{ [self autotestMark:@"2-settings"]; }];
    }];
    [self autotestAfter:8 do:^{
        if (!self.completion) return;
        NSView *documentView = self.settingsScrollView.documentView;
        [documentView scrollPoint:NSMakePoint(0, NSMaxY(documentView.bounds))];
        [self autotestAfter:1.5 do:^{ [self autotestMark:@"3-settings-bottom"]; }];
    }];
    [self autotestAfter:12 do:^{
        if (!self.completion) return;
        // The CI runner is a virtual machine: allow it for the test run.
        self.checkboxes[@"blockVM"].state = NSControlStateValueOff;
        // Screenshots of SEB windows are blocked by default; allow them so the CI can see the exam.
        self.checkboxes[@"blockScreenCapture"].state = NSControlStateValueOff;
        // Test the shared system clipboard and the screen color guard.
        self.checkboxes[@"privateClipboard"].state = NSControlStateValueOff;
        self.checkboxes[@"colorGuard"].state = NSControlStateValueOn;
        [self saveAndStartPressed:self];
        [self autotestAfter:20 do:^{ [self autotestMark:@"4-exam"]; }];
    }];
}

- (void)finishWithStart:(BOOL)start
{
    void (^completion)(BOOL) = self.completion;
    self.completion = nil;
    [self.window orderOut:self];
    if (completion) {
        completion(start);
    }
}

- (void)setContent:(NSView *)view height:(CGFloat)height
{
    NSRect frame = self.window.frame;
    NSRect contentRect = [self.window contentRectForFrameRect:frame];
    CGFloat delta = height - contentRect.size.height;
    frame.size.height += delta;
    frame.origin.y -= delta;
    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    if (screen && frame.origin.y < NSMinY(screen.visibleFrame)) {
        frame.origin.y = NSMinY(screen.visibleFrame);
    }
    self.window.contentView = view;
    [self.window setFrame:frame display:YES animate:NO];
}


#pragma mark - Стартовый экран

- (void)buildStartView
{
    NSTextField *title = [NSTextField labelWithString:@"Контрольная работа"];
    title.font = [NSFont systemFontOfSize:26 weight:NSFontWeightSemibold];

    NSTextField *subtitle = [NSTextField labelWithString:@"Safe Exam Browser"];
    subtitle.font = [NSFont systemFontOfSize:14];
    subtitle.textColor = [NSColor secondaryLabelColor];

    self.levelLabel = [NSTextField labelWithString:@""];
    self.levelLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];

    self.urlLabel = [NSTextField wrappingLabelWithString:@""];
    self.urlLabel.font = [NSFont systemFontOfSize:12];
    self.urlLabel.textColor = [NSColor secondaryLabelColor];
    self.urlLabel.preferredMaxLayoutWidth = SEBTeacherWindowWidth - 80;

    NSButton *startButton = [NSButton buttonWithTitle:@"Начать контрольную" target:self action:@selector(startPressed:)];
    startButton.keyEquivalent = @"\r";

    NSButton *settingsButton = [NSButton buttonWithTitle:@"Настройки преподавателя…" target:self action:@selector(settingsPressed:)];

    NSButton *quitButton = [NSButton buttonWithTitle:@"Выйти" target:self action:@selector(quitPressed:)];

    self.mainButtons = [NSStackView stackViewWithViews:@[startButton, settingsButton, quitButton]];
    self.mainButtons.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.mainButtons.alignment = NSLayoutAttributeCenterX;
    self.mainButtons.spacing = 10;
    for (NSButton *button in @[startButton, settingsButton, quitButton]) {
        if (@available(macOS 11.0, *)) {
            button.controlSize = NSControlSizeLarge;
        }
        [button.widthAnchor constraintEqualToConstant:260].active = YES;
    }

    // Ввод пароля
    self.passwordPrompt = [NSTextField labelWithString:@"Введите пароль преподавателя:"];
    self.passwordField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
    self.passwordField.placeholderString = @"Пароль";
    self.passwordField.target = self;
    self.passwordField.action = @selector(passwordOKPressed:);
    [self.passwordField.widthAnchor constraintEqualToConstant:260].active = YES;

    self.passwordError = [NSTextField labelWithString:@""];
    self.passwordError.textColor = [NSColor systemRedColor];
    self.passwordError.font = [NSFont systemFontOfSize:12];

    self.passwordOKButton = [NSButton buttonWithTitle:@"OK" target:self action:@selector(passwordOKPressed:)];
    NSButton *passwordCancel = [NSButton buttonWithTitle:@"Отмена" target:self action:@selector(passwordCancelPressed:)];
    passwordCancel.keyEquivalent = @"\e";
    NSStackView *passwordButtons = [NSStackView stackViewWithViews:@[passwordCancel, self.passwordOKButton]];
    passwordButtons.spacing = 8;

    self.passwordBox = [NSStackView stackViewWithViews:@[self.passwordPrompt, self.passwordField, self.passwordError, passwordButtons]];
    self.passwordBox.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.passwordBox.alignment = NSLayoutAttributeCenterX;
    self.passwordBox.spacing = 8;
    self.passwordBox.hidden = YES;

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, subtitle, self.levelLabel, self.urlLabel, self.mainButtons, self.passwordBox]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 6;
    [stack setCustomSpacing:24 afterView:self.urlLabel];
    [stack setCustomSpacing:16 afterView:self.mainButtons];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, SEBTeacherWindowWidth, 380)];
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:36],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:view.leadingAnchor constant:30],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:view.trailingAnchor constant:-30],
    ]];
    self.startView = view;
}

- (void)showStartView
{
    SEBTeacherSettings *settings = [SEBTeacherSettings sharedSettings];
    self.levelLabel.stringValue = [NSString stringWithFormat:@"Уровень контроля: %@",
                                   [SEBTeacherSettings titleForPreset:[settings matchingPreset]]];
    NSString *url = settings.startURL;
    self.urlLabel.stringValue = url.length > 0
        ? [NSString stringWithFormat:@"Адрес: %@", url]
        : @"Адрес: из настроек SEB / .seb файла";
    [self hidePasswordBox];
    [self setContent:self.startView height:380];
}

- (void)startPressed:(id)sender
{
    if ([SEBTeacherSettings sharedSettings].requirePasswordToStart) {
        [self askPasswordFor:SEBTeacherPendingActionStart];
    } else {
        [self finishWithStart:YES];
    }
}

- (void)settingsPressed:(id)sender
{
    [self askPasswordFor:SEBTeacherPendingActionOpenSettings];
}

- (void)quitPressed:(id)sender
{
    [self finishWithStart:NO];
}


#pragma mark - Пароль

- (void)askPasswordFor:(SEBTeacherPendingAction)action
{
    self.pendingAction = action;
    self.passwordPrompt.stringValue = action == SEBTeacherPendingActionStart
        ? @"Для начала контрольной введите пароль преподавателя:"
        : @"Для открытия настроек введите пароль преподавателя:";
    self.passwordField.stringValue = @"";
    self.passwordError.stringValue = @"";
    self.mainButtons.hidden = YES;
    self.passwordBox.hidden = NO;
    self.passwordOKButton.keyEquivalent = @"\r";
    [self.window makeFirstResponder:self.passwordField];
}

- (void)hidePasswordBox
{
    self.pendingAction = SEBTeacherPendingActionNone;
    self.passwordField.stringValue = @"";
    self.passwordError.stringValue = @"";
    self.passwordOKButton.keyEquivalent = @"";
    self.passwordBox.hidden = YES;
    self.mainButtons.hidden = NO;
}

- (void)passwordCancelPressed:(id)sender
{
    [self hidePasswordBox];
}

- (void)passwordOKPressed:(id)sender
{
    if (self.pendingAction == SEBTeacherPendingActionNone) {
        return;
    }
    if (self.lockedUntil && [self.lockedUntil timeIntervalSinceNow] > 0) {
        self.passwordError.stringValue = [NSString stringWithFormat:@"Слишком много попыток. Подождите %.0f с.",
                                          ceil([self.lockedUntil timeIntervalSinceNow])];
        return;
    }
    NSString *password = self.passwordField.stringValue;
    self.passwordField.stringValue = @"";

    if (![[SEBTeacherSettings sharedSettings] checkTeacherPassword:password]) {
        self.failedAttempts++;
        if (self.failedAttempts >= SEBTeacherMaxPasswordAttempts) {
            self.failedAttempts = 0;
            self.lockedUntil = [NSDate dateWithTimeIntervalSinceNow:SEBTeacherLockoutSeconds];
            self.passwordError.stringValue = [NSString stringWithFormat:@"Неверный пароль. Ввод заблокирован на %.0f с.", SEBTeacherLockoutSeconds];
        } else {
            self.passwordError.stringValue = @"Неверный пароль";
        }
        NSBeep();
        [self.window makeFirstResponder:self.passwordField];
        return;
    }

    self.failedAttempts = 0;
    SEBTeacherPendingAction action = self.pendingAction;
    [self hidePasswordBox];
    if (action == SEBTeacherPendingActionStart) {
        [self finishWithStart:YES];
    } else {
        [self showSettingsView];
    }
}


#pragma mark - Экран настроек

- (NSView *)separator
{
    NSBox *box = [[NSBox alloc] initWithFrame:NSMakeRect(0, 0, 100, 1)];
    box.boxType = NSBoxSeparator;
    return box;
}

- (NSTextField *)hintLabel:(NSString *)text
{
    NSTextField *hint = [NSTextField wrappingLabelWithString:text];
    hint.font = [NSFont systemFontOfSize:11];
    hint.textColor = [NSColor secondaryLabelColor];
    hint.preferredMaxLayoutWidth = SEBTeacherWindowWidth - 110;
    return hint;
}

- (void)buildSettingsView
{
    // Пресеты
    NSTextField *presetLabel = [NSTextField labelWithString:@"Уровень контроля:"];
    presetLabel.font = [NSFont systemFontOfSize:13 weight:NSFontWeightMedium];
    self.presetControl = [NSSegmentedControl segmentedControlWithLabels:@[[SEBTeacherSettings titleForPreset:SEBTeacherPresetFree],
                                                                          [SEBTeacherSettings titleForPreset:SEBTeacherPresetStandard],
                                                                          [SEBTeacherSettings titleForPreset:SEBTeacherPresetStrict],
                                                                          [SEBTeacherSettings titleForPreset:SEBTeacherPresetCustom]]
                                                           trackingMode:NSSegmentSwitchTrackingSelectOne
                                                                 target:self
                                                                 action:@selector(presetChanged:)];
    [self.presetControl setEnabled:NO forSegment:SEBTeacherPresetCustom];
    NSStackView *presetRow = [NSStackView stackViewWithViews:@[presetLabel, self.presetControl]];
    presetRow.spacing = 10;

    NSTextField *presetHint = [self hintLabel:@"Мягкий — открытая книга; Стандартный — обычная контрольная; Строгий — экзамен. После выбора уровня любой пункт можно изменить вручную."];

    // Содержимое прокрутки
    NSStackView *content = [[NSStackView alloc] initWithFrame:NSZeroRect];
    content.orientation = NSUserInterfaceLayoutOrientationVertical;
    content.alignment = NSLayoutAttributeLeading;
    content.spacing = 4;
    content.edgeInsets = NSEdgeInsetsMake(12, 20, 16, 20);
    content.translatesAutoresizingMaskIntoConstraints = NO;

    NSArray<NSString *> *sections = [SEBTeacherSettings sectionTitles];
    NSArray<SEBTeacherOption *> *options = [SEBTeacherSettings allOptions];
    for (NSInteger section = 0; section < (NSInteger)sections.count; section++) {
        NSTextField *header = [NSTextField labelWithString:sections[section]];
        header.font = [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold];
        [content addArrangedSubview:header];
        if (section > 0) {
            NSView *previous = content.arrangedSubviews[content.arrangedSubviews.count - 2];
            [content setCustomSpacing:18 afterView:previous];
        }
        [content setCustomSpacing:8 afterView:header];

        for (SEBTeacherOption *option in options) {
            if (option.section != section) {
                continue;
            }
            NSButton *checkbox = [NSButton checkboxWithTitle:option.title target:self action:@selector(checkboxChanged:)];
            checkbox.identifier = option.optionID;
            self.checkboxes[option.optionID] = checkbox;
            NSTextField *hint = [self hintLabel:option.hint];
            NSView *indent = [[NSView alloc] initWithFrame:NSZeroRect];
            [indent.widthAnchor constraintEqualToConstant:20].active = YES;
            NSStackView *hintRow = [NSStackView stackViewWithViews:@[indent, hint]];
            hintRow.spacing = 0;
            NSStackView *row = [NSStackView stackViewWithViews:@[checkbox, hintRow]];
            row.orientation = NSUserInterfaceLayoutOrientationVertical;
            row.alignment = NSLayoutAttributeLeading;
            row.spacing = 1;
            [content addArrangedSubview:row];
            [content setCustomSpacing:8 afterView:row];
        }

        if (section == 3) {
            // Пароль выхода
            NSTextField *quitLabel = [NSTextField labelWithString:@"Пароль для выхода и разблокировки экрана:"];
            self.quitPasswordPopup = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
            [self.quitPasswordPopup addItemsWithTitles:@[@"Без пароля", @"Пароль преподавателя", @"Отдельный пароль"]];
            self.quitPasswordPopup.target = self;
            self.quitPasswordPopup.action = @selector(quitPasswordModeChanged:);
            NSStackView *quitRow = [NSStackView stackViewWithViews:@[quitLabel, self.quitPasswordPopup]];
            quitRow.spacing = 8;
            [content addArrangedSubview:quitRow];

            self.customQuitPasswordField = [[NSSecureTextField alloc] initWithFrame:NSZeroRect];
            self.customQuitPasswordField.placeholderString = @"Новый отдельный пароль (пусто — не менять)";
            [self.customQuitPasswordField.widthAnchor constraintEqualToConstant:340].active = YES;
            [content addArrangedSubview:self.customQuitPasswordField];
            [content addArrangedSubview:[self hintLabel:@"Без пароля выход только подтверждается, а заблокированный экран (например, после смены цветов) снимается любым вводом."]];
            [content setCustomSpacing:12 afterView:content.arrangedSubviews.lastObject];

            self.requirePasswordToStartCheckbox = [NSButton checkboxWithTitle:@"Требовать пароль преподавателя для начала контрольной"
                                                                       target:nil
                                                                       action:nil];
            [content addArrangedSubview:self.requirePasswordToStartCheckbox];
            [content addArrangedSubview:[self hintLabel:@"Тогда студент не сможет сам запустить SEB и начать работу."]];
            [content setCustomSpacing:12 afterView:content.arrangedSubviews.lastObject];

            // Адрес
            NSTextField *urlLabel = [NSTextField labelWithString:@"Адрес контрольной (стартовая страница):"];
            [content addArrangedSubview:urlLabel];
            self.startURLField = [[NSTextField alloc] initWithFrame:NSZeroRect];
            self.startURLField.placeholderString = @"https://… (пусто — из настроек SEB / .seb файла)";
            [self.startURLField.widthAnchor constraintEqualToConstant:SEBTeacherWindowWidth - 80].active = YES;
            [content addArrangedSubview:self.startURLField];
        }
    }

    SEBTeacherFlippedView *documentView = [[SEBTeacherFlippedView alloc] initWithFrame:NSZeroRect];
    documentView.translatesAutoresizingMaskIntoConstraints = NO;
    [documentView addSubview:content];

    self.settingsScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    self.settingsScrollView.hasVerticalScroller = YES;
    self.settingsScrollView.drawsBackground = NO;
    self.settingsScrollView.borderType = NSNoBorder;
    self.settingsScrollView.translatesAutoresizingMaskIntoConstraints = NO;
    self.settingsScrollView.documentView = documentView;

    NSClipView *clipView = self.settingsScrollView.contentView;
    [NSLayoutConstraint activateConstraints:@[
        [content.topAnchor constraintEqualToAnchor:documentView.topAnchor],
        [content.leadingAnchor constraintEqualToAnchor:documentView.leadingAnchor],
        [content.trailingAnchor constraintEqualToAnchor:documentView.trailingAnchor],
        [content.bottomAnchor constraintEqualToAnchor:documentView.bottomAnchor],
        [documentView.topAnchor constraintEqualToAnchor:clipView.topAnchor],
        [documentView.leadingAnchor constraintEqualToAnchor:clipView.leadingAnchor],
        [documentView.widthAnchor constraintEqualToAnchor:clipView.widthAnchor],
    ]];

    // Кнопки
    NSButton *resetButton = [NSButton buttonWithTitle:@"Сбросить" target:self action:@selector(resetPressed:)];
    NSButton *cancelButton = [NSButton buttonWithTitle:@"Отмена" target:self action:@selector(settingsCancelPressed:)];
    cancelButton.keyEquivalent = @"\e";
    NSButton *saveButton = [NSButton buttonWithTitle:@"Сохранить" target:self action:@selector(savePressed:)];
    NSButton *saveStartButton = [NSButton buttonWithTitle:@"Сохранить и начать" target:self action:@selector(saveAndStartPressed:)];
    saveStartButton.keyEquivalent = @"\r";
    NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
    [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1 forOrientation:NSLayoutConstraintOrientationHorizontal];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[resetButton, spacer, cancelButton, saveButton, saveStartButton]];
    buttons.spacing = 8;
    buttons.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *top = [[NSView alloc] initWithFrame:NSZeroRect];
    top.translatesAutoresizingMaskIntoConstraints = NO;
    presetRow.translatesAutoresizingMaskIntoConstraints = NO;
    presetHint.translatesAutoresizingMaskIntoConstraints = NO;
    [top addSubview:presetRow];
    [top addSubview:presetHint];

    NSView *topSeparator = [self separator];
    NSView *bottomSeparator = [self separator];
    topSeparator.translatesAutoresizingMaskIntoConstraints = NO;
    bottomSeparator.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, SEBTeacherWindowWidth, 700)];
    for (NSView *subview in @[top, topSeparator, self.settingsScrollView, bottomSeparator, buttons]) {
        [view addSubview:subview];
    }
    [NSLayoutConstraint activateConstraints:@[
        [presetRow.topAnchor constraintEqualToAnchor:top.topAnchor],
        [presetRow.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [presetHint.topAnchor constraintEqualToAnchor:presetRow.bottomAnchor constant:6],
        [presetHint.leadingAnchor constraintEqualToAnchor:top.leadingAnchor],
        [presetHint.trailingAnchor constraintLessThanOrEqualToAnchor:top.trailingAnchor],
        [presetHint.bottomAnchor constraintEqualToAnchor:top.bottomAnchor],

        [top.topAnchor constraintEqualToAnchor:view.topAnchor constant:16],
        [top.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:20],
        [top.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-20],

        [topSeparator.topAnchor constraintEqualToAnchor:top.bottomAnchor constant:12],
        [topSeparator.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [topSeparator.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],

        [self.settingsScrollView.topAnchor constraintEqualToAnchor:topSeparator.bottomAnchor],
        [self.settingsScrollView.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [self.settingsScrollView.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [self.settingsScrollView.bottomAnchor constraintEqualToAnchor:bottomSeparator.topAnchor],

        [bottomSeparator.leadingAnchor constraintEqualToAnchor:view.leadingAnchor],
        [bottomSeparator.trailingAnchor constraintEqualToAnchor:view.trailingAnchor],
        [bottomSeparator.bottomAnchor constraintEqualToAnchor:buttons.topAnchor constant:-12],

        [buttons.leadingAnchor constraintEqualToAnchor:view.leadingAnchor constant:20],
        [buttons.trailingAnchor constraintEqualToAnchor:view.trailingAnchor constant:-20],
        [buttons.bottomAnchor constraintEqualToAnchor:view.bottomAnchor constant:-14],
    ]];
    self.settingsView = view;
}

- (void)showSettingsView
{
    SEBTeacherSettings *settings = [SEBTeacherSettings sharedSettings];
    [settings reload];
    for (SEBTeacherOption *option in [SEBTeacherSettings allOptions]) {
        self.checkboxes[option.optionID].state = [settings boolForOption:option.optionID] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self.quitPasswordPopup selectItemAtIndex:settings.quitPasswordMode];
    self.customQuitPasswordField.stringValue = @"";
    self.requirePasswordToStartCheckbox.state = settings.requirePasswordToStart ? NSControlStateValueOn : NSControlStateValueOff;
    self.startURLField.stringValue = settings.startURL ?: @"";
    [self updateQuitPasswordControls];
    [self updatePresetControl];

    NSScreen *screen = self.window.screen ?: [NSScreen mainScreen];
    CGFloat height = MIN(720, screen ? NSHeight(screen.visibleFrame) - 60 : 720);
    [self setContent:self.settingsView height:height];
    [self.window center];
    [self.settingsScrollView.documentView scrollPoint:NSZeroPoint];
}

- (BOOL)checkboxValue:(NSString *)optionID
{
    return self.checkboxes[optionID].state == NSControlStateValueOn;
}

- (SEBTeacherPreset)presetForCheckboxes
{
    for (SEBTeacherPreset preset = SEBTeacherPresetFree; preset <= SEBTeacherPresetStrict; preset++) {
        BOOL matches = YES;
        for (SEBTeacherOption *option in [SEBTeacherSettings allOptions]) {
            if ([self checkboxValue:option.optionID] != [option valueForPreset:preset]) {
                matches = NO;
                break;
            }
        }
        if (matches) {
            return preset;
        }
    }
    return SEBTeacherPresetCustom;
}

- (void)updatePresetControl
{
    self.presetControl.selectedSegment = [self presetForCheckboxes];
}

- (void)updateQuitPasswordControls
{
    self.customQuitPasswordField.enabled = (self.quitPasswordPopup.indexOfSelectedItem == SEBTeacherQuitPasswordCustom);
}

- (void)presetChanged:(id)sender
{
    SEBTeacherPreset preset = self.presetControl.selectedSegment;
    if (preset == SEBTeacherPresetCustom) {
        return;
    }
    for (SEBTeacherOption *option in [SEBTeacherSettings allOptions]) {
        self.checkboxes[option.optionID].state = [option valueForPreset:preset] ? NSControlStateValueOn : NSControlStateValueOff;
    }
    [self updatePresetControl];
}

- (void)checkboxChanged:(id)sender
{
    [self updatePresetControl];
}

- (void)quitPasswordModeChanged:(id)sender
{
    [self updateQuitPasswordControls];
    if (self.customQuitPasswordField.enabled) {
        [self.window makeFirstResponder:self.customQuitPasswordField];
    }
}

- (void)resetPressed:(id)sender
{
    self.presetControl.selectedSegment = SEBTeacherPresetStandard;
    [self presetChanged:self];
    [self.quitPasswordPopup selectItemAtIndex:SEBTeacherQuitPasswordTeacher];
    self.customQuitPasswordField.stringValue = @"";
    self.requirePasswordToStartCheckbox.state = NSControlStateValueOff;
    self.startURLField.stringValue = @"";
    [self updateQuitPasswordControls];
}

- (void)settingsCancelPressed:(id)sender
{
    [[SEBTeacherSettings sharedSettings] reload];
    [self showStartView];
}

- (void)showError:(NSString *)message info:(NSString *)info
{
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    alert.informativeText = info;
    alert.alertStyle = NSAlertStyleWarning;
    [alert addButtonWithTitle:@"OK"];
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

- (BOOL)storeSettings
{
    SEBTeacherSettings *settings = [SEBTeacherSettings sharedSettings];

    NSString *url = [self.startURLField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (url.length > 0) {
        NSURL *parsed = [NSURL URLWithString:url];
        if (!parsed.scheme || !parsed.host) {
            [self showError:@"Неверный адрес контрольной"
                       info:@"Укажите полный адрес, начиная с https:// (например, https://moodle.example.ru/mod/quiz/view.php?id=123), или оставьте поле пустым."];
            return NO;
        }
    }

    SEBTeacherQuitPasswordMode mode = self.quitPasswordPopup.indexOfSelectedItem;
    NSString *newCustomPassword = self.customQuitPasswordField.stringValue;
    if (mode == SEBTeacherQuitPasswordCustom) {
        if (newCustomPassword.length > 0) {
            settings.hashedCustomQuitPassword = [SEBTeacherSettings sha256HexString:newCustomPassword];
        } else if (settings.hashedCustomQuitPassword.length == 0) {
            [self showError:@"Не задан отдельный пароль"
                       info:@"Введите отдельный пароль для выхода или выберите «Пароль преподавателя»."];
            return NO;
        }
    }
    settings.quitPasswordMode = mode;
    settings.requirePasswordToStart = (self.requirePasswordToStartCheckbox.state == NSControlStateValueOn);
    settings.startURL = url;
    for (SEBTeacherOption *option in [SEBTeacherSettings allOptions]) {
        [settings setBool:[self checkboxValue:option.optionID] forOption:option.optionID];
    }

    if (![settings save]) {
        [self showError:@"Не удалось сохранить настройки"
                   info:@"Настройки будут действовать только до выхода из SEB."];
    }
    return YES;
}

- (void)savePressed:(id)sender
{
    if ([self storeSettings]) {
        [self showStartView];
    }
}

- (void)saveAndStartPressed:(id)sender
{
    if ([self storeSettings]) {
        [self finishWithStart:YES];
    }
}

@end


#pragma mark - SEBастьян: ключ доступа

// Адрес сервера SEBастьяна. Можно переопределить ключом SEBastianServerURL в Info.plist.
static NSString * const SEBAccessKeyDefaultServer = @"https://seb.korova.pro";
static const CGFloat SEBAccessKeyWindowWidth = 460;

@interface SEBAccessKeyGate ()
@property (nonatomic, copy, nullable) void (^completion)(BOOL proceed);
@property (nonatomic, strong, nullable) NSWindow *window;
@property (nonatomic, strong) NSTextField *infoLabel;
@property (nonatomic, strong) NSTextField *keyField;
@property (nonatomic, strong) NSTextField *errorLabel;
@property (nonatomic, strong) NSButton *continueButton;
@property (nonatomic, strong) NSButton *retryButton;
@property (nonatomic, strong) NSProgressIndicator *spinner;
@property (nonatomic, copy) NSString *botURL;
@property (nonatomic) BOOL busy;
@end

@implementation SEBAccessKeyGate

+ (instancetype)sharedGate
{
    static SEBAccessKeyGate *shared = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        shared = [SEBAccessKeyGate new];
        shared.botURL = @"https://t.me/";
    });
    return shared;
}

- (NSString *)serverURL
{
    NSString *url = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"SEBastianServerURL"];
    if (![url isKindOfClass:[NSString class]] || url.length == 0) {
        url = SEBAccessKeyDefaultServer;
    }
    while ([url hasSuffix:@"/"]) {
        url = [url substringToIndex:url.length - 1];
    }
    return url;
}

#pragma mark Кэш режима (на случай, если сервер недоступен)

- (NSURL *)cacheURL
{
    NSURL *appSupport = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                               inDomains:NSUserDomainMask].firstObject;
    NSURL *directory = [appSupport URLByAppendingPathComponent:@"SEB Teacher Panel" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL];
    return [directory URLByAppendingPathComponent:@"AccessKeyGate.plist"];
}

/// -1 — неизвестно (сервер ещё ни разу не отвечал), 0 — ключ не нужен, 1 — нужен.
- (NSInteger)cachedRequired
{
    NSDictionary *cache = [NSDictionary dictionaryWithContentsOfURL:[self cacheURL]];
    NSNumber *value = cache[@"required"];
    return [value isKindOfClass:[NSNumber class]] ? (value.boolValue ? 1 : 0) : -1;
}

- (void)storeRequired:(BOOL)required
{
    [@{@"required" : @(required), @"time" : [NSDate date]} writeToURL:[self cacheURL] atomically:YES];
}

#pragma mark Сеть

- (NSDictionary *)deviceInfo
{
    NSString *device = [NSHost currentHost].localizedName ?: @"";
    NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    return @{@"platform" : @"mac", @"device" : device, @"user" : NSUserName() ?: @"", @"version" : version};
}

- (void)request:(NSString *)path
           body:(nullable NSDictionary *)body
     completion:(void (^)(NSInteger status, NSDictionary * _Nullable json, NSError * _Nullable error))completion
{
    NSURL *url = [NSURL URLWithString:[[self serverURL] stringByAppendingString:path]];
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:10];
    if (body) {
        request.HTTPMethod = @"POST";
        [request setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
        request.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:NULL];
    }
    NSURLSessionConfiguration *configuration = [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.timeoutIntervalForRequest = 10;
    configuration.timeoutIntervalForResource = 15;
    NSURLSession *session = [NSURLSession sessionWithConfiguration:configuration];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        NSInteger status = [response isKindOfClass:[NSHTTPURLResponse class]] ? ((NSHTTPURLResponse *)response).statusCode : 0;
        NSDictionary *json = nil;
        if (data.length > 0) {
            id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            if ([parsed isKindOfClass:[NSDictionary class]]) {
                json = parsed;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(status, json, error);
        });
    }] resume];
    [session finishTasksAndInvalidate];
}

- (void)reportLaunch
{
    NSMutableDictionary *body = [[self deviceInfo] mutableCopy];
    body[@"event"] = @"launch";
    [self request:@"/api/v1/launch" body:body completion:^(NSInteger status, NSDictionary *json, NSError *error) {}];
}

#pragma mark Запуск

- (void)runWithCompletion:(void (^)(BOOL proceed))completion
{
    // Автотест в CI (только с верным паролем преподавателя) не зависит от сервера.
    NSString *autotest = [NSProcessInfo processInfo].environment[@"SEB_TEACHER_AUTOTEST_PASSWORD"];
    if (autotest.length > 0 && [[SEBTeacherSettings sharedSettings] checkTeacherPassword:autotest]) {
        completion(YES);
        return;
    }
    if (self.completion) {
        // Проверка уже идёт (окно открыто) — просто обновляем, кого уведомить.
        self.completion = completion;
        return;
    }
    self.completion = completion;
    [self request:@"/api/v1/gate?platform=mac" body:nil completion:^(NSInteger status, NSDictionary *json, NSError *error) {
        if (status == 200 && [json[@"required"] isKindOfClass:[NSNumber class]]) {
            BOOL required = [json[@"required"] boolValue];
            if ([json[@"bot"] isKindOfClass:[NSString class]]) {
                self.botURL = json[@"bot"];
            }
            [self storeRequired:required];
            if (required) {
                [self showWindowWithError:nil offline:NO];
            } else {
                [self reportLaunch];
                [self finish:YES];
            }
            return;
        }
        NSLog(@"[SEBastian] Gate check failed (HTTP %ld): %@", (long)status, error.localizedDescription);
        if ([self cachedRequired] == 0) {
            [self finish:YES]; // в прошлый раз ключ был не нужен — не мешаем работать без интернета
        } else {
            [self showWindowWithError:@"Нет связи с сервером SEBастьяна. Включи VPN, проверь интернет и нажми «Повторить»."
                              offline:YES];
        }
    }];
}

- (void)finish:(BOOL)proceed
{
    void (^completion)(BOOL) = self.completion;
    self.completion = nil;
    if (self.window) {
        [self.window orderOut:self];
        self.window = nil;
    }
    if (completion) {
        completion(proceed);
    }
}

#pragma mark Окно

- (void)buildWindow
{
    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, SEBAccessKeyWindowWidth, 370)
                                                   styleMask:NSWindowStyleMaskTitled
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"SEBастьян — ключ доступа";
    window.releasedWhenClosed = NO;
    window.level = NSModalPanelWindowLevel;
    window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorFullScreenAuxiliary;
    window.delegate = self;

    NSTextField *title = [NSTextField labelWithString:@"Ключ доступа"];
    title.font = [NSFont systemFontOfSize:24 weight:NSFontWeightSemibold];

    self.infoLabel = [NSTextField wrappingLabelWithString:
        @"Получи ключ в Telegram-боте SEBастьян («Получить ключ») и введи его ниже. Один ключ — один запуск.\n\nНужен включённый VPN: так SEB сможет проверить ключ. После входа VPN можно выключить."];
    self.infoLabel.alignment = NSTextAlignmentCenter;
    self.infoLabel.font = [NSFont systemFontOfSize:13];
    self.infoLabel.preferredMaxLayoutWidth = SEBAccessKeyWindowWidth - 60;

    self.keyField = [[NSTextField alloc] initWithFrame:NSZeroRect];
    self.keyField.placeholderString = @"например K7F3QX";
    self.keyField.alignment = NSTextAlignmentCenter;
    if (@available(macOS 10.15, *)) {
        self.keyField.font = [NSFont monospacedSystemFontOfSize:24 weight:NSFontWeightSemibold];
    } else {
        self.keyField.font = [NSFont userFixedPitchFontOfSize:24];
    }
    self.keyField.target = self;
    self.keyField.action = @selector(continuePressed:);
    [self.keyField.widthAnchor constraintEqualToConstant:260].active = YES;

    self.errorLabel = [NSTextField wrappingLabelWithString:@""];
    self.errorLabel.textColor = [NSColor systemRedColor];
    self.errorLabel.alignment = NSTextAlignmentCenter;
    self.errorLabel.font = [NSFont systemFontOfSize:12];
    self.errorLabel.preferredMaxLayoutWidth = SEBAccessKeyWindowWidth - 60;

    self.spinner = [[NSProgressIndicator alloc] initWithFrame:NSZeroRect];
    self.spinner.style = NSProgressIndicatorStyleSpinning;
    self.spinner.controlSize = NSControlSizeSmall;
    self.spinner.displayedWhenStopped = NO;

    self.continueButton = [NSButton buttonWithTitle:@"Продолжить" target:self action:@selector(continuePressed:)];
    self.continueButton.keyEquivalent = @"\r";
    self.retryButton = [NSButton buttonWithTitle:@"Повторить" target:self action:@selector(retryPressed:)];
    NSButton *botButton = [NSButton buttonWithTitle:@"Открыть бота" target:self action:@selector(botPressed:)];
    NSButton *quitButton = [NSButton buttonWithTitle:@"Выйти" target:self action:@selector(quitPressed:)];
    NSStackView *buttons = [NSStackView stackViewWithViews:@[quitButton, botButton, self.retryButton, self.continueButton]];
    buttons.spacing = 8;

    NSStackView *stack = [NSStackView stackViewWithViews:@[title, self.infoLabel, self.keyField, self.spinner, self.errorLabel, buttons]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeCenterX;
    stack.spacing = 10;
    [stack setCustomSpacing:18 afterView:self.infoLabel];
    [stack setCustomSpacing:18 afterView:self.errorLabel];
    stack.translatesAutoresizingMaskIntoConstraints = NO;

    NSView *view = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, SEBAccessKeyWindowWidth, 370)];
    [view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.centerXAnchor constraintEqualToAnchor:view.centerXAnchor],
        [stack.topAnchor constraintEqualToAnchor:view.topAnchor constant:28],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:view.trailingAnchor constant:-24],
        [stack.bottomAnchor constraintLessThanOrEqualToAnchor:view.bottomAnchor constant:-20],
    ]];
    window.contentView = view;
    self.window = window;
}

- (BOOL)windowShouldClose:(NSWindow *)sender
{
    return NO;
}

- (void)showWindowWithError:(nullable NSString *)error offline:(BOOL)offline
{
    if (!self.window) {
        [self buildWindow];
        [self.window center];
    }
    self.errorLabel.stringValue = error ?: @"";
    self.keyField.hidden = offline;
    self.continueButton.hidden = offline;
    self.retryButton.hidden = !offline;
    self.retryButton.keyEquivalent = offline ? @"\r" : @"";
    self.continueButton.keyEquivalent = offline ? @"" : @"\r";
    [self setBusy:NO];
    [NSApp activateIgnoringOtherApps:YES];
    [self.window makeKeyAndOrderFront:self];
    if (!offline) {
        [self.window makeFirstResponder:self.keyField];
    }
}

- (void)setBusy:(BOOL)busy
{
    _busy = busy;
    self.keyField.enabled = !busy;
    self.continueButton.enabled = !busy;
    self.retryButton.enabled = !busy;
    if (busy) {
        [self.spinner startAnimation:self];
    } else {
        [self.spinner stopAnimation:self];
    }
}

- (void)continuePressed:(id)sender
{
    if (self.busy) {
        return;
    }
    NSString *key = [self.keyField.stringValue stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (key.length == 0) {
        self.errorLabel.stringValue = @"Введи ключ из бота.";
        NSBeep();
        return;
    }
    self.errorLabel.stringValue = @"";
    [self setBusy:YES];
    NSMutableDictionary *body = [[self deviceInfo] mutableCopy];
    body[@"key"] = key;
    [self request:@"/api/v1/redeem" body:body completion:^(NSInteger status, NSDictionary *json, NSError *error) {
        [self setBusy:NO];
        if (status == 200 && [json[@"ok"] boolValue]) {
            NSLog(@"[SEBastian] Access key accepted.");
            [self finish:YES];
            return;
        }
        NSString *message = [json[@"message"] isKindOfClass:[NSString class]] ? json[@"message"] : nil;
        if (!message) {
            message = status == 0
                ? @"Нет связи с сервером SEBастьяна. Включи VPN и проверь интернет, потом попробуй ещё раз."
                : [NSString stringWithFormat:@"Сервер ответил ошибкой (%ld). Попробуй ещё раз.", (long)status];
        }
        self.errorLabel.stringValue = message;
        NSBeep();
        [self.window makeFirstResponder:self.keyField];
        [self.keyField selectText:self];
    }];
}

- (void)retryPressed:(id)sender
{
    [self setBusy:YES];
    self.errorLabel.stringValue = @"Проверяю связь…";
    void (^completion)(BOOL) = self.completion;
    self.completion = nil;
    [self runWithCompletion:completion];
}

- (void)botPressed:(id)sender
{
    NSURL *url = [NSURL URLWithString:self.botURL.length > 13 ? self.botURL : [[self serverURL] stringByAppendingString:@"/bot"]];
    if (url) {
        [[NSWorkspace sharedWorkspace] openURL:url];
    }
}

- (void)quitPressed:(id)sender
{
    [self finish:NO];
}

@end
