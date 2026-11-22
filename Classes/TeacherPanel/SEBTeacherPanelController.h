//
//  SEBTeacherPanelController.h
//  Safe Exam Browser — Teacher Panel
//
//  Окно, которое показывается при запуске SEB до начала контрольной:
//  «Начать контрольную», «Настройки преподавателя…» (по паролю), «Выйти».
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface SEBTeacherPanelController : NSWindowController <NSWindowDelegate>

+ (instancetype)sharedController;

/// Показать панель. completion(YES) — начать контрольную, completion(NO) — выйти из SEB.
- (void)showWithCompletion:(void (^)(BOOL startExam))completion;

@end


/// SEBастьян: ключ доступа перед запуском. Если на сервере включён вход по ключу,
/// показывает окно ввода одноразового ключа из Telegram-бота и проверяет его на сервере.
@interface SEBAccessKeyGate : NSObject <NSWindowDelegate>

+ (instancetype)sharedGate;

/// completion(YES) — можно продолжать запуск, completion(NO) — выйти из SEB.
- (void)runWithCompletion:(void (^)(BOOL proceed))completion;

@end

NS_ASSUME_NONNULL_END
