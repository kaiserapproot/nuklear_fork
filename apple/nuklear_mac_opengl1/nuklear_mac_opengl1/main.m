/*
 * ================================================================================
 * Nuklear UIフレームワークのmacOS実装における重要な変更点
 * ================================================================================
 * 
 * 【問題】
 * macOSでNuklearウィンドウのドラッグ移動が機能しない問題がありました。
 * この問題は、Windowsと異なり、macOSではイベント処理とレンダリングが
 * 別スレッドで実行されることが原因でした。
 * 
 * 【解決策の詳細】
 * 
 * 1. イベントキュー方式の導入:
 *    - マウスイベントが発生した時点で直接Nuklearに通知せず、キューに追加
 *    - NSMutableArrayとNSLockを使用してスレッドセーフなキューを実装
 *    - イベント情報（種類、位置、ボタン状態）をNSDictionaryに格納
 * 
 * 2. マウス入力からNuklearへの通知プロセス:
 *    - mouseDown/Up: nk_input_button(ctx, NK_BUTTON_LEFT, x, y, 0/1)
 *    - mouseDragged/Moved: nk_input_motion(ctx, x, y)
 *    - マウス座標はmacOSの座標系（左下原点）からOpenGL/Nuklearの座標系（左上原点）に変換
 *      y = viewHeight - y
 * 
 * 3. スレッド間同期とロック:
 *    - eventLockを使用して複数スレッドからのイベントキューへのアクセスを排他制御
 *    - [eventLock lock]と[eventLock unlock]でクリティカルセクションを保護
 *    - pendingEventsの読み取り/書き込みはすべてロックで保護
 * 
 * 4. ディスプレイリンク処理:
 *    - CVDisplayLinkCreateWithActiveCGDisplays: ディスプレイリンクの作成
 *    - CVDisplayLinkSetOutputCallback: レンダリングコールバック関数を設定
 *    - displayLinkCallback関数: 別スレッドでの実行を避けるため
 *      dispatch_async(dispatch_get_main_queue(), ^{ [self renderFrame]; });
 *      を使ってメインスレッドでレンダリング処理を実行
 * 
 * 5. レンダリングサイクルの流れ:
 *    a. openGLContextをアクティブに設定
 *    b. nk_input_begin(ctx)で入力処理の開始
 *    c. キューから全イベントを取り出し、Nuklearに通知
 *       - mouseMove/Drag -> nk_input_motion
 *       - mouseDown/Up -> nk_input_button
 *    d. nk_input_end(ctx)で入力処理の終了
 *    e. drawUI()でNuklearのUIを定義（nk_begin -> nk_widgets -> nk_end）
 *    f. nk_gl1_render()でOpenGLにレンダリング
 *    g. flushBufferでバッファスワップ
 * 
 * 6. イベントハンドラの実装:
 *    - mouseDown/mouseUp: 左ボタンの状態を追跡し、イベントをキューに追加
 *    - mouseMoved/mouseDragged: 現在位置を更新し、イベントをキューに追加
 *    - mouseEntered/Exited: マウスのウィンドウ内外状態を追跡
 * 
 * この実装により、Nuklearウィンドウのドラッグ移動が正しく機能するようになりました。
 * 主な改善点は、イベント処理とレンダリングの同期を確保し、Windowsの実装に近い
 * 処理フローを実現したことです。
 */
#import <Cocoa/Cocoa.h>
#import <OpenGL/gl.h>
#import <OpenGL/glu.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>

// Nuklear関連のヘッダー
#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_IMPLEMENTATION
#include "nuklear.h"
#define NK_GL1_IMPLEMENTATION
#include "nuklear_gl.h" // OpenGL 1.1用 Nuklear バックエンド（必要に応じて用意）

@interface NuklearView : NSOpenGLView
- (instancetype)initWithFrame:(NSRect)frameRect;
- (void)setupNuklear;
- (void)renderFrame;
- (void)drawUI;
@end

@implementation NuklearView {
    NSOpenGLContext *glContext;
    CVDisplayLinkRef displayLink;
    NSTrackingArea *trackingArea;
    struct nk_context *ctx;
    
    // 入力状態を集約する変数
    NSMutableArray *pendingEvents;  // 保留中のイベント
    NSLock *eventLock;              // イベント配列のロック
    BOOL needsRedraw;               // 再描画フラグ
    
    // マウス状態
    NSPoint mousePos;
    BOOL leftButtonDown;
    BOOL rightButtonDown;
}

// ディスプレイリンクのコールバック関数（レンダリングスレッド）
static CVReturn displayLinkCallback(CVDisplayLinkRef displayLink,
                                   const CVTimeStamp *now,
                                   const CVTimeStamp *outputTime,
                                   CVOptionFlags flagsIn,
                                   CVOptionFlags *flagsOut,
                                   void *displayLinkContext)
{
    @autoreleasepool {
        NuklearView *view = (__bridge NuklearView *)displayLinkContext;
        [view renderFrameFromDisplayLink];
    }
    return kCVReturnSuccess;
}

// 初期化
- (instancetype)initWithFrame:(NSRect)frameRect {
    NSOpenGLPixelFormatAttribute attrs[] = {
        NSOpenGLPFADoubleBuffer,
        NSOpenGLPFADepthSize, 24,
        NSOpenGLPFAOpenGLProfile, NSOpenGLProfileVersionLegacy,
        0
    };
    
    NSOpenGLPixelFormat *format = [[NSOpenGLPixelFormat alloc] initWithAttributes:attrs];
    
    if (self = [super initWithFrame:frameRect pixelFormat:format]) {
        // イベント同期用の変数を初期化
        pendingEvents = [NSMutableArray array];
        eventLock = [[NSLock alloc] init];
        needsRedraw = YES;
        
        // マウス状態の初期化
        mousePos = NSZeroPoint;
        leftButtonDown = NO;
        rightButtonDown = NO;
        
        // OpenGLコンテキスト設定
        glContext = [self openGLContext];
        
        // ディスプレイリンク設定
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
        CVDisplayLinkSetOutputCallback(displayLink, displayLinkCallback, (__bridge void *)self);
        
        // ディスプレイリンクとOpenGLコンテキストを同期
        CGLContextObj cglContext = [[self openGLContext] CGLContextObj];
        CGLPixelFormatObj cglPixelFormat = [[self pixelFormat] CGLPixelFormatObj];
        CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(displayLink, cglContext, cglPixelFormat);
    }
    
    return self;
}

// レンダリングスレッドからのレンダリング（ディスプレイリンク用）
- (void)renderFrameFromDisplayLink {
    // メインスレッドでの処理を要求
    dispatch_async(dispatch_get_main_queue(), ^{
        [self renderFrame];
    });
}

// OpenGL初期化
- (void)prepareOpenGL {
    [super prepareOpenGL];
    
    // OpenGL初期化
    [[self openGLContext] makeCurrentContext];
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glDisable(GL_CULL_FACE);
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_SCISSOR_TEST);
    glEnable(GL_TEXTURE_2D);
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glEnableClientState(GL_COLOR_ARRAY);
    
    // VSync設定
    GLint swapInt = 1;
    [[self openGLContext] setValues:&swapInt forParameter:NSOpenGLCPSwapInterval];
    
    // Nuklearを初期化
    [self setupNuklear];
    
    // マウスイベント設定
    [[self window] setAcceptsMouseMovedEvents:YES];
    
    // トラッキングエリア設定
    [self updateTrackingAreas];
    
    // ディスプレイリンク開始
    CVDisplayLinkStart(displayLink);
    
    NSLog(@"prepareOpenGL完了");
}

// Nuklear初期化
- (void)setupNuklear {
    NSLog(@"setupNuklear開始");
    
    // Nuklear初期化
    ctx = nk_gl1_init(NK_GL1_DEFAULT);
    
    // フォント設定
    struct nk_font_atlas *atlas;
    nk_gl1_font_stash_begin(&atlas);
    struct nk_font *font = nk_font_atlas_add_default(atlas, 16.0f, NULL);
    nk_gl1_font_stash_end();
    
    // フォントを明示的に設定
    if (font) {
        nk_style_set_font(ctx, &font->handle);
        NSLog(@"フォント設定完了");
    }
    
    // ウィンドウサイズをNuklearに設定
    NSSize size = [self bounds].size;
    nk_gl1_resize(size.width, size.height);
    
    NSLog(@"setupNuklear完了: ctx=%p", ctx);
}

// ウィンドウ座標からOpenGL座標に変換（Y軸反転）
- (NSPoint)convertToGLCoordinates:(NSPoint)windowPoint {
    NSPoint viewPoint = [self convertPoint:windowPoint fromView:nil];
    viewPoint.y = self.bounds.size.height - viewPoint.y; // Y座標反転
    return viewPoint;
}

// ================= イベント処理 =================
// イベントをキューに追加するヘルパーメソッド
- (void)queueEvent:(NSDictionary *)event {
    [eventLock lock];
    [pendingEvents addObject:event];
    needsRedraw = YES;
    [eventLock unlock];
}

// マウスダウン
- (void)mouseDown:(NSEvent *)event {
    NSPoint point = [self convertToGLCoordinates:[event locationInWindow]];
    mousePos = point;
    leftButtonDown = YES;
    
    [self queueEvent:@{
        @"type": @"mouseDown",
        @"button": @(NK_BUTTON_LEFT),
        @"position": [NSValue valueWithPoint:point]
    }];
    
    NSLog(@"MouseDown at (%.1f, %.1f)", point.x, point.y);
}

// マウスアップ
- (void)mouseUp:(NSEvent *)event {
    NSPoint point = [self convertToGLCoordinates:[event locationInWindow]];
    mousePos = point;
    leftButtonDown = NO;
    
    [self queueEvent:@{
        @"type": @"mouseUp",
        @"button": @(NK_BUTTON_LEFT),
        @"position": [NSValue valueWithPoint:point]
    }];
    
    NSLog(@"MouseUp at (%.1f, %.1f)", point.x, point.y);
}

// マウス移動
- (void)mouseMoved:(NSEvent *)event {
    NSPoint point = [self convertToGLCoordinates:[event locationInWindow]];
    mousePos = point;
    
    [self queueEvent:@{
        @"type": @"mouseMove",
        @"position": [NSValue valueWithPoint:point]
    }];
}

// マウスドラッグ
- (void)mouseDragged:(NSEvent *)event {
    NSPoint point = [self convertToGLCoordinates:[event locationInWindow]];
    mousePos = point;
    
    [self queueEvent:@{
        @"type": @"mouseDrag",
        @"position": [NSValue valueWithPoint:point]
    }];
    
    // ドラッグログ（必要に応じて）
    static int dragCounter = 0;
    if (dragCounter++ % 30 == 0) {
        NSLog(@"MouseDrag at (%.1f, %.1f)", point.x, point.y);
    }
}

// 右マウスボタン処理
- (void)rightMouseDown:(NSEvent *)event {
    NSPoint point = [self convertToGLCoordinates:[event locationInWindow]];
    mousePos = point;
    rightButtonDown = YES;
    
    [self queueEvent:@{
        @"type": @"mouseDown",
        @"button": @(NK_BUTTON_RIGHT),
        @"position": [NSValue valueWithPoint:point]
    }];
}

- (void)rightMouseUp:(NSEvent *)event {
    NSPoint point = [self convertToGLCoordinates:[event locationInWindow]];
    mousePos = point;
    rightButtonDown = NO;
    
    [self queueEvent:@{
        @"type": @"mouseUp",
        @"button": @(NK_BUTTON_RIGHT),
        @"position": [NSValue valueWithPoint:point]
    }];
}

// 右ドラッグ処理
- (void)rightMouseDragged:(NSEvent *)event {
    [self mouseDragged:event];
}

// スクロールイベント
- (void)scrollWheel:(NSEvent *)event {
    [self queueEvent:@{
        @"type": @"scroll",
        @"deltaX": @([event deltaX]),
        @"deltaY": @([event deltaY])
    }];
}

// マウス入退場イベント
- (void)mouseEntered:(NSEvent *)event {
    [self queueEvent:@{
        @"type": @"mouseEntered"
    }];
}

- (void)mouseExited:(NSEvent *)event {
    [self queueEvent:@{
        @"type": @"mouseExited"
    }];
    
    // マウスがビューを出たことを記録
    mousePos = NSMakePoint(-1, -1);
}

// ================= レンダリング =================
// メインのレンダリングメソッド
- (void)renderFrame {
    [[self openGLContext] makeCurrentContext];
    
    // 画面クリア
    glClearColor(0.2f, 0.2f, 0.2f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    
    // ここでWindowsのサンプルと同じ流れで処理:
    // 1. nk_input_begin
    // 2. イベント処理
    // 3. nk_input_end
    // 4. UI描画
    // 5. レンダリング
    
    // 1. 入力処理開始
    nk_input_begin(ctx);
    
    // 2. イベント処理（キューからイベントを取り出して処理）
    [eventLock lock];
    NSArray *events = [pendingEvents copy];
    [pendingEvents removeAllObjects];
    [eventLock unlock];
    
    for (NSDictionary *event in events) {
        NSString *type = event[@"type"];
        
        if ([type isEqualToString:@"mouseMove"] || [type isEqualToString:@"mouseDrag"]) {
            NSPoint point = [event[@"position"] pointValue];
            nk_input_motion(ctx, point.x, point.y);
        } 
        else if ([type isEqualToString:@"mouseDown"]) {
            NSPoint point = [event[@"position"] pointValue];
            int button = [event[@"button"] intValue];
            nk_input_button(ctx, button, point.x, point.y, 1);
        } 
        else if ([type isEqualToString:@"mouseUp"]) {
            NSPoint point = [event[@"position"] pointValue];
            int button = [event[@"button"] intValue];
            nk_input_button(ctx, button, point.x, point.y, 0);
        }
        else if ([type isEqualToString:@"scroll"]) {
            float deltaX = [event[@"deltaX"] floatValue];
            float deltaY = [event[@"deltaY"] floatValue];
            nk_input_scroll(ctx, nk_vec2(deltaX, deltaY));
        }
        else if ([type isEqualToString:@"mouseExited"]) {
            // マウスが外れた場合の処理（オプション）
        }
    }
    
    // 3. 入力処理終了
    nk_input_end(ctx);
    
    // 4. UI描画
    [self drawUI];
    
    // 5. Nuklear描画
    nk_gl1_render(NK_ANTI_ALIASING_ON);
    
    // バッファスワップ
    [[self openGLContext] flushBuffer];
}

// UI描画
- (void)drawUI {
    // メインウィンドウを描画
    if (nk_begin(ctx, "Nuklear Demo", nk_rect(50, 50, 300, 400),
                NK_WINDOW_BORDER | 
                NK_WINDOW_MOVABLE | 
                NK_WINDOW_SCALABLE |
                NK_WINDOW_MINIMIZABLE | 
                NK_WINDOW_TITLE))
    {
        // 静的な変数
        static int property = 20;
        static int option = 1;
        static float slider = 0.5f;
        static struct nk_colorf color = {0.5f, 0.3f, 0.4f, 1.0f};
        
        // 英語ラベル
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_label(ctx, "Hello World", NK_TEXT_CENTERED);
        
        // ボタン
        nk_layout_row_static(ctx, 30, 80, 1);
        if (nk_button_label(ctx, "Button")) {
            NSLog(@"Button pressed");
        }
        
        // オプション
        nk_layout_row_dynamic(ctx, 30, 2);
        if (nk_option_label(ctx, "Option 1", option == 1)) option = 1;
        if (nk_option_label(ctx, "Option 2", option == 2)) option = 2;
        
        // プロパティ
        nk_layout_row_dynamic(ctx, 22, 1);
        nk_property_int(ctx, "Property:", 0, &property, 100, 1, 1);
        
        // スライダー
        nk_layout_row_dynamic(ctx, 22, 1);
        nk_label(ctx, "Slider:", NK_TEXT_LEFT);
        nk_layout_row_dynamic(ctx, 22, 1);
        slider = nk_slide_float(ctx, 0.0f, slider, 1.0f, 0.01f);
        
        // カラーピッカー
        color.r = slider;
        nk_layout_row_dynamic(ctx, 150, 1);
        color = nk_color_picker(ctx, color, NK_RGB);
        
        // 色情報
        nk_layout_row_dynamic(ctx, 30, 1);
        char buffer[64];
        snprintf(buffer, sizeof(buffer), "Color: R:%.2f G:%.2f B:%.2f", 
                color.r, color.g, color.b);
        nk_label(ctx, buffer, NK_TEXT_LEFT);
        
        // マウス情報表示（デバッグ用）
        nk_layout_row_dynamic(ctx, 30, 1);
        snprintf(buffer, sizeof(buffer), 
                 "Mouse: (%.0f, %.0f) Delta: (%.0f, %.0f)", 
                 mousePos.x, mousePos.y,
                 ctx->input.mouse.delta.x, ctx->input.mouse.delta.y);
        nk_label(ctx, buffer, NK_TEXT_LEFT);
        
        // ボタン状態表示
        nk_layout_row_dynamic(ctx, 30, 1);
        snprintf(buffer, sizeof(buffer), "Left: %s Right: %s", 
                 leftButtonDown ? "DOWN" : "UP",
                 rightButtonDown ? "DOWN" : "UP");
        nk_label(ctx, buffer, NK_TEXT_LEFT);
    }
    nk_end(ctx);
}

// リサイズ処理
- (void)reshape {
    [super reshape];
    
    // Nuklearにビューサイズ変更を通知
    NSSize size = [self bounds].size;
    [[self openGLContext] makeCurrentContext];
    nk_gl1_resize(size.width, size.height);
    
    // OpenGLビューポート設定
    glViewport(0, 0, size.width, size.height);
    
    // トラッキングエリア更新
    [self updateTrackingAreas];
    
    // 再描画フラグを設定
    needsRedraw = YES;
    
    NSLog(@"reshape: サイズ変更 (%.0f, %.0f)", size.width, size.height);
}

// トラッキングエリア更新
- (void)updateTrackingAreas {
    [super updateTrackingAreas];
    
    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
    }
    
    trackingArea = [[NSTrackingArea alloc] initWithRect:[self bounds]
                                               options:(NSTrackingMouseEnteredAndExited |
                                                        NSTrackingMouseMoved |
                                                        NSTrackingActiveInKeyWindow)
                                                 owner:self
                                              userInfo:nil];
    [self addTrackingArea:trackingArea];
}

// 表示領域が無効になった場合の処理
- (void)drawRect:(NSRect)dirtyRect {
    [self renderFrame];
}

// ファーストレスポンダーになれるようにする
- (BOOL)acceptsFirstResponder {
    return YES;
}

// リソースの解放
- (void)dealloc {
    NSLog(@"dealloc: リソース解放開始");
    
    // ディスプレイリンクの停止と解放
    if (displayLink) {
        CVDisplayLinkStop(displayLink);
        CVDisplayLinkRelease(displayLink);
    }
    
    // トラッキングエリアの解放
    if (trackingArea) {
        [self removeTrackingArea:trackingArea];
    }
    
    // OpenGLコンテキストを現在のスレッドに設定
    [[self openGLContext] makeCurrentContext];
    
    // Nuklearリソースのシャットダウン
    if (ctx) {
        nk_gl1_shutdown();
        ctx = NULL;
    }
    
    // OpenGLコンテキストをクリア
    [NSOpenGLContext clearCurrentContext];
    
    NSLog(@"dealloc: リソース解放完了");
}

@end

// アプリケーションデリゲート
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // ウィンドウの作成
    NSRect screenRect = [[NSScreen mainScreen] frame];
    NSRect windowRect = NSMakeRect(screenRect.size.width/4, screenRect.size.height/4, 
                                  800, 600);
    
    NSWindowStyleMask style = NSWindowStyleMaskTitled | 
                              NSWindowStyleMaskClosable | 
                              NSWindowStyleMaskMiniaturizable |
                              NSWindowStyleMaskResizable;
                              
    self.window = [[NSWindow alloc] initWithContentRect:windowRect
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    
    [self.window setTitle:@"Nuklear OpenGL Demo"];
    [self.window setAcceptsMouseMovedEvents:YES];
    
    // OpenGLViewの作成
    NuklearView *view = [[NuklearView alloc] initWithFrame:[self.window.contentView bounds]];
    [view setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [self.window.contentView addSubview:view];
    
    // ウィンドウ表示
    [self.window makeKeyAndOrderFront:nil];
    [self.window center];
    
    // 明示的にビューをファーストレスポンダーに設定
    [self.window makeFirstResponder:view];
    
    NSLog(@"アプリケーション起動完了");
}

@end

// メイン関数
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        // アプリケーション作成と実行
        NSApplication *application = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [application setDelegate:delegate];
        [application run];
    }
    return 0;
}
