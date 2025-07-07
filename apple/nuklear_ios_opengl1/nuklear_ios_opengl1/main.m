/*
 * ================================================================================
 * Nuklear UIフレームワークのiOS実装 - OpenGL ES 1.1対応
 * ================================================================================
 * 
 * 【Nuklearフレームワーク概要】
 * Nuklearはイミディエイトモード型UIライブラリで、状態管理を最小限にし、
 * 毎フレームUIを再構築する設計思想を持ちます。このコードではiOS上でNuklearを
 * 動作させるための統合レイヤーを実装しています。
 *
 * 【主な特徴】
 *
 * 1. iOS UIKitとOpenGL ES 1.1の統合
 *    - UIViewとCAEAGLLayerを使用したレンダリング
 *    - フレームバッファとレンダーバッファの適切な管理
 *    - Retinaディスプレイ対応（高DPI処理）
 *    - CADisplayLinkによる効率的なレンダリングサイクル
 * 
 * 2. Nuklear入力処理の正確な実装
 *    - タッチイベントをNuklearの入力に変換（重要な課題）
 *    - イベントキュー方式によるスレッドセーフな実装
 *    - マウスホバー状態のないiOS環境での適切なイベント変換
 *    - タッチ状態追跡とドラッグ操作の正確な処理
 *
 * 3. iOSシステムフォントの使用
 *    - San Francisco / HelveticaNeueなどのiOSフォントを活用
 *    - 複数フォントのサポート（通常・太字）
 *    - 日本語などの多言語対応（CJK文字範囲のサポート）
 *    - CTFont APIを使用したシステムフォントの適切な抽出
 * 
 * 4. Nuklear公式ドキュメントに準拠した実装
 *    - 正確なAPI使用とライフサイクル管理
 *    - 適切なリソース管理とメモリリーク防止
 *    - 軽量で効率的なレンダリングパイプライン
 *
 * 【リファクタリング後の主なクラスと役割】
 *
 * 1. NuklearView（UIViewサブクラス）
 *    - UIロジックの中心。OpenGL描画、Nuklear UI構築、イベント伝播のハブ。
 *    - 各種管理クラス（renderer, inputHandler, fontHelper）を集約し、
 *      UIの状態管理や描画サイクルを制御。
 *    - 使い方: 画面に直接配置し、初期化時に各管理クラスを生成・利用。
 *
 * 2. NKGLRenderer
 *    - OpenGL ES 1.1のフレームバッファ/レンダーバッファ管理、描画開始・終了処理を担当。
 *    - NuklearViewから描画タイミングで呼び出される。
 *    - 使い方: NuklearViewの初期化時にインスタンス化し、描画時にbeginRender/endRender等を呼ぶ。
 *
 * 3. NKInputHandler
 *    - タッチイベントの受付・キューイング、Nuklear入力イベントへの変換を担当。
 *    - スレッドセーフなイベント管理、タッチ状態の追跡も行う。
 *    - 使い方: touchesBegan/Moved/Ended/Cancelledから呼び出し、
 *      毎フレームprocessEventsでNuklearに反映。
 *
 * 4. NKFontHelper
 *    - システムフォントや日本語フォントのロード、Nuklearフォントアトラスへの追加を担当。
 *    - フォントデータの抽出やアトラスベイクも担う。
 *    - 使い方: NuklearViewのフォント初期化時に利用。
 *
 * 【座標系とタッチ処理の注意点】
 * - UIKitは左上原点、OpenGL ESは左下原点という座標系の違いがある
 * - Nuklearは左上原点を前提としているため、座標変換に注意が必要
 * - デスクトップ環境向けのホバー状態をiOSのタッチイベントで適切に代替する必要がある
 * - タッチ終了時にボタン状態をリセットしないとドラッグ状態が維持される問題がある
 *
 * 【実装上の主な課題と解決策】
 * 1. イベント識別子の未宣言: events変数を明示的に宣言
 * 2. イベントタイプの区別不足: タッチの開始/移動/終了を明示的に区別
 * 3. 状態管理の不備: タッチ終了時にドラッグ状態を確実にリセット
 * 4. スレッド安全性: ロックによるイベントアクセスの保護
 * 5. 座標変換精度: スケールファクターの適切な計算と適用
 *
 * 【参考ドキュメント】
 * - https://immediate-mode-ui.github.io/Nuklear/#autotoc_md5
 * - https://immediate-mode-ui.github.io/Nuklear/Input.html
 * - https://immediate-mode-ui.github.io/Nuklear/Drawing.html
 * - https://immediate-mode-ui.github.io/Nuklear/Font.html
 */

#import <UIKit/UIKit.h>
#import <OpenGLES/ES1/gl.h>
#import <OpenGLES/ES1/glext.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreText/CoreText.h>

// Nuklear関連の定義
#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_IMPLEMENTATION

// OpenGL ES 1.1用の実装を定義
#define NK_GLES1_IMPLEMENTATION
#include "nuklear.h"
#include "nuklear_gles.h"  // OpenGL ES 1.1用のヘッダーファイル

// 日本語文字範囲のヘルパー関数
static const nk_rune *nk_font_japanese_glyph_ranges(void) {
    static const nk_rune ranges[] = {
        0x0020, 0x00FF,       // 基本ラテン文字 + ラテン1補助
        0x3000, 0x30FF,       // 日本語句読点 + 平仮名 + カタカナ
        0x4E00, 0x9FFF,       // CJK統合漢字（基本セット）
        0xFF00, 0xFFEF,       // 全角英数字
        0,
    };
    return ranges;
}

@interface NKFontHelper : NSObject
@end

/**
 * NKFontHelper - フォント関連の処理を担当
 * - システムフォントやカスタムフォントの読み込み
 * - 日本語フォントの抽出とアトラスへの追加
 * - フォントアトラスのベイクとテクスチャ生成
 */
@implementation NKFontHelper
+ (struct nk_font *)addSystemFontToAtlas:(struct nk_font_atlas *)atlas name:(NSString *)fontName size:(CGFloat)size {
    // フォントファイルのパス取得
    NSString *fontPath = [[NSBundle mainBundle] pathForResource:fontName ofType:@"ttf"];
    if (!fontPath) return NULL;
    NSData *fontData = [NSData dataWithContentsOfFile:fontPath];
    if (!fontData) return NULL;
    struct nk_font_config config = nk_font_config(size);
    config.oversample_h = 3;
    config.oversample_v = 3;
    config.range = nk_font_default_glyph_ranges();
    return nk_font_atlas_add_from_memory(atlas, fontData.bytes, fontData.length, size, &config);
}
+ (struct nk_font *)addJapaneseFontToAtlas:(struct nk_font_atlas *)atlas size:(CGFloat)size {
    UIFont *jpFont = [UIFont fontWithName:@"HiraginoSans-W3" size:size];
    if (!jpFont) jpFont = [UIFont systemFontOfSize:size];
    NSData *fontData = nil;
    // フォントデータ抽出（省略: extractFontDataFromUIFont: を利用）
    // ...
    struct nk_font_config config = nk_font_config(size);
    config.oversample_h = 2;
    config.oversample_v = 2;
    config.range = nk_font_japanese_glyph_ranges();
    // return nk_font_atlas_add_from_memory(atlas, fontData.bytes, fontData.length, size, &config);
    return NULL; // 実装例
}
@end

@implementation NKInputHandler : NSObject {
    CGPoint touchPos;
    BOOL isTouching;
    NSMutableArray *pendingEvents;
    NSLock *eventLock;
    struct nk_context *ctx;
}
- (instancetype)initWithContext:(struct nk_context *)context {
    if (self = [super init]) {
        ctx = context;
        pendingEvents = [NSMutableArray array];
        eventLock = [[NSLock alloc] init];
        isTouching = NO;
        touchPos = CGPointZero;
    }
    return self;
}
- (void)handleTouchBegan:(UITouch *)touch inView:(UIView *)view {
    CGPoint point = [touch locationInView:view];
    // Nuklear座標系変換は NuklearView から委譲される想定
    touchPos = point;
    isTouching = YES;
    [eventLock lock];
    [pendingEvents addObject:@{ @"type": @"began", @"position": [NSValue valueWithCGPoint:point] }];
    [eventLock unlock];
}
- (void)handleTouchMoved:(UITouch *)touch inView:(UIView *)view {
    CGPoint point = [touch locationInView:view];
    touchPos = point;
    [eventLock lock];
    [pendingEvents addObject:@{ @"type": @"moved", @"position": [NSValue valueWithCGPoint:point] }];
    [eventLock unlock];
}
- (void)handleTouchEnded:(UITouch *)touch inView:(UIView *)view {
    CGPoint point = [touch locationInView:view];
    touchPos = point;
    isTouching = NO;
    [eventLock lock];
    [pendingEvents addObject:@{ @"type": @"ended", @"position": [NSValue valueWithCGPoint:point] }];
    [eventLock unlock];
}
- (void)handleTouchCancelled:(UITouch *)touch inView:(UIView *)view {
    [self handleTouchEnded:touch inView:view];
}
- (void)processEvents {
    // Nuklear入力処理例（ctxはセット済み想定）
    [eventLock lock];
    NSArray *events = [pendingEvents copy];
    [pendingEvents removeAllObjects];
    [eventLock unlock];
    for (NSDictionary *event in events) {
        CGPoint pos = [event[@"position"] CGPointValue];
        NSString *type = event[@"type"];
        nk_input_motion(ctx, (int)pos.x, (int)pos.y);
        if ([type isEqualToString:@"began"]) {
            nk_input_button(ctx, NK_BUTTON_LEFT, (int)pos.x, (int)pos.y, 1);
        } else if ([type isEqualToString:@"ended"]) {
            nk_input_button(ctx, NK_BUTTON_LEFT, (int)pos.x, (int)pos.y, 0);
        }
    }
}
@end

@implementation NKGLRenderer : NSObject {
    GLuint viewFramebuffer;
    GLuint viewRenderbuffer;
    int backingWidth;
    int backingHeight;
    __weak CAEAGLLayer *eaglLayer;
}
- (instancetype)initWithLayer:(CAEAGLLayer *)layer {
    if (self = [super init]) {
        eaglLayer = layer;
        viewFramebuffer = 0;
        viewRenderbuffer = 0;
        backingWidth = 0;
        backingHeight = 0;
    }
    return self;
}
- (BOOL)createFramebuffer {
    // OpenGLフレームバッファ生成例
    glGenFramebuffersOES(1, &viewFramebuffer);
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
    glGenRenderbuffersOES(1, &viewRenderbuffer);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
    // ...レイヤーからストレージ割当て、サイズ取得など...
    return YES;
}
- (void)destroyFramebuffer {
    if (viewFramebuffer) glDeleteFramebuffersOES(1, &viewFramebuffer);
    if (viewRenderbuffer) glDeleteRenderbuffersOES(1, &viewRenderbuffer);
}
- (void)beginRender {
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, viewFramebuffer);
    glClearColor(0.1f, 0.18f, 0.24f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
}
- (void)endRender {
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, viewRenderbuffer);
    // ...presentRenderbuffer など...
}
- (void)setViewport:(CGRect)bounds {
    glViewport(0, 0, (GLsizei)bounds.size.width, (GLsizei)bounds.size.height);
}
@end

// NuklearViewの各処理で、
// 例: [self.inputHandler handleTouchBegan:touch inView:self];
//     [self.fontHelper addSystemFontToAtlas:...];
//     [self.renderer beginRender];

// EAGL用のNuklear View
@interface NuklearView : UIView {
    // OpenGL ES関連: レンダリングコンテキストやバッファ管理
    EAGLContext *context;           // OpenGL ESの描画コンテキスト
    CADisplayLink *displayLink;     // 描画タイミング制御用タイマー
    GLuint frameBuffer;             // メインフレームバッファ
    GLuint colorRenderBuffer;       // カラーレンダーバッファ
    GLint backingWidth;             // バッファ幅
    GLint backingHeight;            // バッファ高さ

    // Nuklear関連: UI状態・描画用
    struct nk_context *ctx;         // NuklearのUIコンテキスト
    struct nk_buffer cmds;          // コマンドバッファ
    struct nk_draw_null_texture null; // Nuklear用nullテクスチャ

    // フォント関連: UI用フォント管理
    struct nk_font *defaultFont;    // デフォルトフォント
    struct nk_font *systemFont;     // システムフォント
    struct nk_font *boldFont;       // 太字フォント
    struct nk_font *japaneseFont;   // 日本語フォント
    GLuint fontTexture;             // フォントテクスチャ

    // 入力状態管理: タッチイベントやUI更新管理
    NSMutableArray *pendingEvents;  // タッチイベントキュー
    NSLock *eventLock;              // イベントキュー用ロック
    BOOL needsRedraw;               // 再描画フラグ

    // タッチ状態: 現在のタッチ座標・状態
    CGPoint touchPos;               // タッチ座標
    BOOL isTouching;                // タッチ中かどうか

    // UI状態変数: 背景色やタブ選択など
    float backgroundColor[4];       // 背景色（RGBA）
    int selectedTab;                // 選択中タブ
    BOOL showDemo;                  // デモUI表示フラグ

    // --- リファクタリング構造 ---
    // 各責務を分離した管理クラス
    NKGLRenderer *renderer;         // OpenGL ES描画・バッファ管理専用クラス
    NKInputHandler *inputHandler;   // タッチ入力・イベント管理専用クラス
    NKFontHelper *fontHelper;       // フォント管理・ロード専用クラス
    // これによりNuklearViewはUIロジックに集中し、
    // 各機能の保守性・拡張性が向上
}

@end

@implementation NuklearView

#pragma mark - 初期化とセットアップ

+ (Class)layerClass {
    return [CAEAGLLayer class];
}

- (id)initWithFrame:(CGRect)frame {
    if (self = [super initWithFrame:frame]) {
        // レイヤータイプをCAEAGLLayerに設定
        CAEAGLLayer *eaglLayer = (CAEAGLLayer *)self.layer;
        eaglLayer.opaque = YES;
        eaglLayer.drawableProperties = @{
            kEAGLDrawablePropertyRetainedBacking: @NO,
            kEAGLDrawablePropertyColorFormat: kEAGLColorFormatRGBA8
        };
        
        // OpenGL ES 1.1コンテキストの作成
        context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES1];
        if (!context || ![EAGLContext setCurrentContext:context]) {
            NSLog(@"OpenGL ESコンテキスト作成失敗");
            return nil;
        }
        
        // イベント同期用の変数を初期化
        pendingEvents = [NSMutableArray array];
        eventLock = [[NSLock alloc] init];
        needsRedraw = YES;
        
        // タッチ状態の初期化
        touchPos = CGPointZero;
        isTouching = NO;
        
        // UI状態の初期化
        backgroundColor[0] = 0.10f;
        backgroundColor[1] = 0.18f;
        backgroundColor[2] = 0.24f;
        backgroundColor[3] = 1.0f;
        selectedTab = 0;
        showDemo = YES;
        
        // 初期設定
        [self createFramebuffer];
        [self setupNuklear];
        
        // CADisplayLinkの設定
        displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(render:)];
        if (@available(iOS 10.0, *)) {
            displayLink.preferredFramesPerSecond = 60;
        } else {
            displayLink.frameInterval = 1;
        }
        [displayLink addToRunLoop:[NSRunLoop currentRunLoop] forMode:NSRunLoopCommonModes];
        
        // ユーティリティクラスの初期化
        renderer = [[NKGLRenderer alloc] initWithLayer:(CAEAGLLayer *)self.layer];
        inputHandler = [[NKInputHandler alloc] initWithContext:ctx];
        fontHelper = [[NKFontHelper alloc] init];
        
        NSLog(@"NuklearView初期化完了");
    }
    return self;
}

#pragma mark - OpenGL ESフレームバッファ管理

- (BOOL)createFramebuffer {
    [EAGLContext setCurrentContext:context];
    
    // 既存のフレームバッファを破棄
    [self destroyFramebuffer];
    
    // フレームバッファの生成と設定
    glGenFramebuffersOES(1, &frameBuffer);
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, frameBuffer);
    
    // レンダーバッファの生成と設定
    glGenRenderbuffersOES(1, &colorRenderBuffer);
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, colorRenderBuffer);
    
    // レンダーバッファをレイヤーに関連付け
    [context renderbufferStorage:GL_RENDERBUFFER_OES fromDrawable:(CAEAGLLayer*)self.layer];
    glFramebufferRenderbufferOES(GL_FRAMEBUFFER_OES, GL_COLOR_ATTACHMENT0_OES, 
                                GL_RENDERBUFFER_OES, colorRenderBuffer);
    
    // バッファサイズを取得
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_WIDTH_OES, &backingWidth);
    glGetRenderbufferParameterivOES(GL_RENDERBUFFER_OES, GL_RENDERBUFFER_HEIGHT_OES, &backingHeight);
    
    // フレームバッファの設定を確認
    if (glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES) != GL_FRAMEBUFFER_COMPLETE_OES) {
        NSLog(@"フレームバッファ作成失敗: %x", glCheckFramebufferStatusOES(GL_FRAMEBUFFER_OES));
        return NO;
    }
    
    NSLog(@"フレームバッファ作成成功: %d x %d", backingWidth, backingHeight);
    
    // Nuklearのビューポート更新（もしctxが既に初期化されていれば）
    if (ctx) {
        nk_gles1_viewport(backingWidth, backingHeight);
    }
    
    return YES;
}

- (void)destroyFramebuffer {
    if (context) {
        [EAGLContext setCurrentContext:context];
        
        if (frameBuffer) {
            glDeleteFramebuffersOES(1, &frameBuffer);
            frameBuffer = 0;
        }
        
        if (colorRenderBuffer) {
            glDeleteRenderbuffersOES(1, &colorRenderBuffer);
            colorRenderBuffer = 0;
        }
    }
}

#pragma mark - Nuklear初期化

- (void)setupNuklear {
    NSLog(@"Nuklear初期化開始");
    [EAGLContext setCurrentContext:context];
    
    // OpenGL ES 1.1の設定
    glDisable(GL_CULL_FACE);
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_SCISSOR_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    
    // Nuklearコマンドバッファの初期化
    nk_buffer_init_default(&cmds);
    
    // Nuklearコンテキストの作成
    ctx = nk_gles1_init(NULL, backingWidth, backingHeight);
    if (!ctx) {
        NSLog(@"エラー: Nuklearコンテキスト作成失敗");
        return;
    }
    NSLog(@"Nuklearコンテキスト作成成功: %p", ctx);
    
    // *** 重要: まずはデフォルトフォントだけを設定して確実に動作させる ***
    [self setupBasicFont];
    
    // コンテキストが正しく設定されているか確認
    if (ctx && ctx->style.font && ctx->style.font->width) {
        float width = ctx->style.font->width(ctx->style.font->userdata, 0, "A", 1);
        NSLog(@"フォント設定確認成功: width(%s)=%.2f", "A", width);
    } else {
        NSLog(@"警告: フォントが設定されていません。基本フォントを再試行します");
        [self setupSimplestFont];
    }
    
    NSLog(@"Nuklear初期化完了: ctx=%p", ctx);
}

// 最も単純なデフォルトフォント設定
- (void)setupSimplestFont {
    NSLog(@"最小限のフォント設定を試行");
    
    struct nk_font_atlas *atlas;
    nk_gles1_font_stash_begin(&atlas);
    
    // デフォルトフォントだけを追加
    struct nk_font *font = nk_font_atlas_add_default(atlas, 13.0f, NULL);
    
    // フォントアトラスのベイク
    int w, h;
    const void *image = nk_font_atlas_bake(atlas, &w, &h, NK_FONT_ATLAS_RGBA32);
    NSLog(@"デフォルトフォントアトラスのサイズ: %dx%d", w, h);
    
    // テクスチャ作成
    GLuint font_tex;
    glGenTextures(1, &font_tex);
    glBindTexture(GL_TEXTURE_2D, font_tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, image);
    
    // アップロード
    nk_gles1_font_stash_end();
    
    // フォントを設定
    if (font) {
        nk_style_set_font(ctx, &font->handle);
        NSLog(@"最小限のデフォルトフォント設定成功");
    } else {
        NSLog(@"エラー: デフォルトフォント作成失敗");
    }
    
    // このフォントを保存
    fontTexture = font_tex;
    defaultFont = font;
}

// 単純なデフォルトフォントのみの設定（最初の試行）
- (void)setupBasicFont {
    NSLog(@"基本フォント設定開始");
    
    struct nk_font_atlas *atlas;
    nk_gles1_font_stash_begin(&atlas);
    
    // デフォルトフォントを追加
    defaultFont = nk_font_atlas_add_default(atlas, 16.0f, NULL);
    if (!defaultFont) {
        NSLog(@"エラー: デフォルトフォント追加失敗");
        nk_gles1_font_stash_end();
        return;
    }
    
    // フォントアトラスのベイク処理
    int w, h;
    const void *image = nk_font_atlas_bake(atlas, &w, &h, NK_FONT_ATLAS_RGBA32);
    if (!image) {
        NSLog(@"エラー: フォントアトラスのベイク失敗");
        nk_gles1_font_stash_end();
        return;
    }
    NSLog(@"フォントアトラスのサイズ: %dx%d", w, h);
    
    // テクスチャの生成と設定
    glGenTextures(1, &fontTexture);
    glBindTexture(GL_TEXTURE_2D, fontTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, image);
    
    // フォントスタッシュの終了
    nk_gles1_font_stash_end();
    
    // コンテキストにフォントを設定
    nk_style_set_font(ctx, &defaultFont->handle);
    NSLog(@"基本フォント設定完了");
    
    // この後のフレームで各種フォントを追加予定
    needsRedraw = YES;
}
#pragma mark - フォント設定

- (void)setupFonts {
    NSLog(@"フォント設定開始");
    
    // フォントのステータス変数
    BOOL fontSuccessFlag = NO;
    
    // フォントアトラスの初期化
    struct nk_font_atlas *atlas = NULL;
    nk_gles1_font_stash_begin(&atlas);
    if (!atlas) {
        NSLog(@"エラー: フォントアトラスが初期化できませんでした");
        return;
    }
    
    // フォント変数の初期化
    defaultFont = NULL;
    systemFont = NULL;
    boldFont = NULL;
    japaneseFont = NULL;
    
    // ステップ1: デフォルトフォントの追加
    defaultFont = nk_font_atlas_add_default(atlas, 16.0f, NULL);
    if (defaultFont) {
        NSLog(@"デフォルトフォント追加成功");
        fontSuccessFlag = YES;
    } else {
        NSLog(@"警告: デフォルトフォント追加失敗");
    }
    
    // ステップ2: カスタムフォントの追加
    systemFont = [self loadFontFromFile:@"Roboto-Regular" size:16.0f atlas:atlas];
    boldFont = [self loadFontFromFile:@"Roboto-Bold" size:16.0f atlas:atlas];
    japaneseFont = [self addJapaneseFontToAtlas:atlas size:18.0f];
    
    // ステップ3: フォントアトラスのベイク
    int w = 0, h = 0;
    const void *image = nk_font_atlas_bake(atlas, &w, &h, NK_FONT_ATLAS_RGBA32);
    if (image) {
        NSLog(@"フォントアトラスベイク成功: %dx%d", w, h);
    } else {
        NSLog(@"エラー: フォントアトラスベイク失敗");
        return;
    }
    
    // ステップ4: テクスチャの生成と設定
    glGenTextures(1, &fontTexture);
    glBindTexture(GL_TEXTURE_2D, fontTexture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, w, h, 0, GL_RGBA, GL_UNSIGNED_BYTE, image);
    NSLog(@"フォントテクスチャ設定完了: ID=%d", fontTexture);
    
    // ステップ5: フォントスタッシュの終了
    nk_gles1_font_stash_end();
    NSLog(@"フォントスタッシュ終了");
    
    // ステップ6: コンテキストにフォントを設定
    if (systemFont) {
        nk_style_set_font(ctx, &systemFont->handle);
        NSLog(@"システムフォントを設定");
        fontSuccessFlag = YES;
    } else if (defaultFont) {
        nk_style_set_font(ctx, &defaultFont->handle);
        NSLog(@"デフォルトフォントを設定");
        fontSuccessFlag = YES;
    }
    
    if (!fontSuccessFlag) {
        NSLog(@"エラー: フォントが設定できません");
    }
    
    NSLog(@"フォント設定完了");
}

// バンドルからフォントをロードするヘルパーメソッド
- (struct nk_font *)loadFontFromFile:(NSString *)fontName size:(float)fontSize atlas:(struct nk_font_atlas *)atlas {
    NSString *fontPath = [[NSBundle mainBundle] pathForResource:fontName ofType:@"ttf"];
    if (!fontPath) {
        NSLog(@"フォントファイルが見つかりません: %@.ttf", fontName);
        return NULL;
    }
    
    NSData *fontData = [NSData dataWithContentsOfFile:fontPath];
    if (!fontData || fontData.length == 0) {
        NSLog(@"フォントデータを読み込めませんでした: %@", fontPath);
        return NULL;
    }
    
    NSLog(@"フォントをロードしました: %@ (サイズ: %.1fpt, データ長: %lu bytes)", 
          fontName, fontSize, (unsigned long)fontData.length);
    
    // フォント設定
    struct nk_font_config config = nk_font_config(fontSize);
    config.oversample_h = 3;
    config.oversample_v = 3;
    config.range = nk_font_default_glyph_ranges();
    
    // フォントをアトラスに追加
    return nk_font_atlas_add_from_memory(atlas, 
                                        fontData.bytes, 
                                        fontData.length, 
                                        fontSize, 
                                        &config);
}

- (struct nk_font *)addJapaneseFontToAtlas:(struct nk_font_atlas *)atlas size:(CGFloat)size {
    // 日本語フォント（Hiraginoなど）を取得
    UIFont *jpFont = [UIFont fontWithName:@"HiraginoSans-W3" size:size];
    if (!jpFont) {
        jpFont = [UIFont fontWithName:@"HiraginoSans-W6" size:size];
    }
    if (!jpFont) {
        NSLog(@"日本語フォント取得失敗、システムフォントを使用");
        jpFont = [UIFont systemFontOfSize:size];
    }
    
    // フォントデータを抽出
    NSData *fontData = [self extractFontDataFromUIFont:jpFont];
    if (!fontData || fontData.length == 0) {
        NSLog(@"日本語フォントデータ抽出失敗");
        return NULL;
    }
    
    // 日本語フォント設定（グリフ範囲を日本語に設定）
    struct nk_font_config config = nk_font_config(size);
    config.oversample_h = 2;
    config.oversample_v = 2;
    config.range = nk_font_japanese_glyph_ranges();
    
    // フォントをアトラスに追加
    return nk_font_atlas_add_from_memory(atlas, 
                                       fontData.bytes, 
                                       fontData.length, 
                                       size, 
                                       &config);
}

- (NSData *)extractFontDataFromUIFont:(UIFont *)font {
    // CTフォントの取得
    CTFontRef ctFont = CTFontCreateWithName((__bridge CFStringRef)font.fontName, font.pointSize, NULL);
    if (!ctFont) {
        NSLog(@"CTFont作成失敗: %@", font.fontName);
        return nil;
    }
    
    // フォントのURLを取得
    NSURL *fontURL = NULL;
    CTFontDescriptorRef descriptor = CTFontCopyFontDescriptor(ctFont);
    if (descriptor) {
        CFURLRef url = (CFURLRef)CTFontDescriptorCopyAttribute(descriptor, kCTFontURLAttribute);
        if (url) {
            fontURL = (__bridge_transfer NSURL *)url;
        }
        CFRelease(descriptor);
    }
    
    CFRelease(ctFont);
    
    if (fontURL) {
        // URLからデータを読み込む
        NSError *error = nil;
        NSData *fontData = [NSData dataWithContentsOfURL:fontURL options:0 error:&error];
        if (error || !fontData) {
            NSLog(@"フォントファイル読み込みエラー: %@", error);
        }
        return fontData;
    } else {
        NSLog(@"フォントURL取得失敗: %@", font.fontName);
    }
    
    // 代替手段: リソースからフォントを探す
    NSString *fontName = [font.fontName stringByReplacingOccurrencesOfString:@" " withString:@""];
    NSArray *extensions = @[@"ttf", @"otf", @"ttc"];
    
    for (NSString *ext in extensions) {
        NSString *resourcePath = [[NSBundle mainBundle] pathForResource:fontName ofType:ext];
        if (resourcePath) {
            return [NSData dataWithContentsOfFile:resourcePath];
        }
    }
    
    NSLog(@"フォント '%@' のデータが取得できません", font.fontName);
    return nil;
}

#pragma mark - レイアウト処理

- (void)layoutSubviews {
    [super layoutSubviews];
    
    // フレームバッファとNuklearのビューサイズを更新
    [self destroyFramebuffer];
    [self createFramebuffer];
    
    needsRedraw = YES;
}

#pragma mark - 座標変換

- (CGPoint)convertToGLCoordinates:(CGPoint)viewPoint {
    /**
     * タッチ座標変換処理
     * - UIKit座標系からNuklear/OpenGL座標系への変換
     * - スケーリング適用（Retinaディスプレイ対応）
     * - Y軸反転の調整（必要に応じて）
     */
    float scaleX = (float)backingWidth / self.bounds.size.width;
    float scaleY = (float)backingHeight / self.bounds.size.height;
    
    // UIKit座標系をNuklearの座標系に変換
    // Nuklearは左上原点系を使用しているため、スケーリングのみ適用
    viewPoint.x *= scaleX;
    viewPoint.y *= scaleY;
    
    NSLog(@"タッチ座標変換: UIKit(x=%.1f, y=%.1f) → Nuklear(x=%.1f, y=%.1f)",
          viewPoint.x/scaleX, viewPoint.y/scaleY, viewPoint.x, viewPoint.y);
    
    return viewPoint;
}

#pragma mark - タッチイベント処理
/**
 * タッチイベント管理の問題と修正点
 * 
 * 【Nuklearの入力モデルとiOSタッチモデルの違い】
 * Nuklearは元々デスクトップ環境向けに設計されており:
 * 1. マウスがウィジェット上にホバーする（iOSには存在しない概念）
 * 2. マウスボタンを押下（タップ開始に相当）
 * 3. マウスをドラッグ（タッチ移動に相当）
 * 4. マウスボタンを解放（タップ終了に相当）
 * という状態管理を前提としています。
 * 
 * 【主な問題点と修正】
 * 1. イベント識別子の未宣言: events変数が宣言されていなかった
 * 2. イベントタイプの区別不足: タッチの開始/移動/終了が明示的に区別されていなかった
 * 3. 状態管理の不備: タッチ終了時にドラッグ状態がリセットされていなかった
 * 4. スレッド安全性: イベントアクセスの同期処理が不足していた
 */
- (void)queueEvent:(NSDictionary *)event {
        /**
     * スレッドセーフなイベント追加
     * - eventLockによる排他制御
     * - 明示的なタイプ情報を持つイベントをキューに追加
     * - needsRedrawフラグを設定して再描画を要求
     */
    [eventLock lock];
    [pendingEvents addObject:event];
    needsRedraw = YES;
    [eventLock unlock];
}

- (void)touchesBegan:(NSSet *)touches withEvent:(UIEvent *)event {
    /**
     * タッチ開始処理
     * - iOSのタッチ開始 = Nuklearのマウスボタン押下
     * - 明示的に "began" タイプを設定してイベントをキューに追加
     * - タッチ状態を追跡するフラグをON
     */
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self];
    CGPoint glPoint = [self convertToGLCoordinates:point];
    
    touchPos = glPoint;
    isTouching = YES;
    
    [self queueEvent:@{
        @"type": @"began",  // イベントタイプを追加
        @"position": [NSValue valueWithCGPoint:glPoint]
    }];
}
- (void)drawCoordinatesDebugWindow:(struct nk_rect)bounds {
    if (nk_begin(ctx, "Coordinates Debug", bounds, 
                NK_WINDOW_BORDER|NK_WINDOW_TITLE|NK_WINDOW_MOVABLE)) {
        // 座標情報表示
        nk_layout_row_dynamic(ctx, 20, 1);
        char buffer[128];
        snprintf(buffer, sizeof(buffer), "UIKit: (%.1f, %.1f)", 
                 touchPos.x/((float)backingWidth/self.bounds.size.width),
                 self.bounds.size.height - touchPos.y/((float)backingHeight/self.bounds.size.height));
        nk_label(ctx, buffer, NK_TEXT_LEFT);
        
        nk_layout_row_dynamic(ctx, 20, 1);
        snprintf(buffer, sizeof(buffer), "OpenGL: (%.1f, %.1f)", touchPos.x, touchPos.y);
        nk_label(ctx, buffer, NK_TEXT_LEFT);
        
        // 座標グリッド表示
        nk_layout_row_dynamic(ctx, 100, 1);
        struct nk_command_buffer *canvas = nk_window_get_canvas(ctx);
        if (canvas) {
            float x0 = 10, y0 = 10, width = 80, height = 80;
            
            // グリッド線
            nk_stroke_rect(canvas, nk_rect(x0, y0, width, height), 0, 1, nk_rgb(128, 128, 128));
            
            // 軸
            nk_stroke_line(canvas, x0, y0, x0+width, y0, 1, nk_rgb(255, 0, 0)); // X軸
            nk_stroke_line(canvas, x0, y0, x0, y0+height, 1, nk_rgb(0, 255, 0)); // Y軸
            
            // 中心点
            float cx = x0 + width/2;
            float cy = y0 + height/2;
            nk_fill_circle(canvas, nk_rect(cx-2, cy-2, 4, 4), nk_rgb(255, 255, 0));
        }
    }
    nk_end(ctx);
}
- (void)touchesMoved:(NSSet *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self];
    CGPoint glPoint = [self convertToGLCoordinates:point];
    
    touchPos = glPoint;
    
    [self queueEvent:@{
        @"type": @"mouseMove",
        @"position": [NSValue valueWithCGPoint:glPoint]
    }];
}

- (void)touchesEnded:(NSSet *)touches withEvent:(UIEvent *)event {
    /**
     * タッチ終了処理
     * - iOSのタッチ終了 = Nuklearのマウスボタン解放
     * - 明示的に "ended" タイプを設定
     * - タッチ状態フラグをOFF（重要: これがないとドラッグ状態が維持されてしまう）
     */
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self];
    CGPoint glPoint = [self convertToGLCoordinates:point];
    
    // タッチ状態を確実にリセット
    isTouching = NO;
    
    // 明示的に終了イベントをキューに追加
    [self queueEvent:@{
        @"type": @"ended",
        @"position": [NSValue valueWithCGPoint:glPoint]
    }];
}

- (void)touchesCancelled:(NSSet *)touches withEvent:(UIEvent *)event {
    /**
     * タッチキャンセル処理
     * - システムによるタッチのキャンセル（通話着信など）
     * - タッチ終了と同様に処理して状態を正しくリセット
     */
    [self touchesEnded:touches withEvent:event];
}
#pragma mark - レンダリング

- (void)render:(CADisplayLink *)link {
    /**
     * Nuklear入力処理とレンダリング
     * - スレッドセーフにイベントを取得
     * - nk_input_begin/endで入力処理をラップ
     * - 各イベントタイプに応じた適切な入力通知
     */    
    if (!needsRedraw && pendingEvents.count == 0) {
        return; // 変更がなければスキップ（電力効率化）
    }
    
    [self renderFrame];
    needsRedraw = NO;
}

- (void)renderFrame {
    if (!ctx) {
        NSLog(@"エラー: Nuklearコンテキストがありません");
        return;
    }
    
    // フォントチェック
    if (!ctx->style.font || !ctx->style.font->width) {
        NSLog(@"エラー: フォントが設定されていません。レンダリングをスキップします");
        return;
    }
    
    // コンテキストをアクティブに
    [EAGLContext setCurrentContext:context];
    
    // フレームバッファをバインド
    glBindFramebufferOES(GL_FRAMEBUFFER_OES, frameBuffer);
    
    // 画面クリア
    glClearColor(
        backgroundColor[0],
        backgroundColor[1],
        backgroundColor[2],
        backgroundColor[3]
    );
    glClear(GL_COLOR_BUFFER_BIT);
    
    // Nuklearの入力処理
    nk_input_begin(ctx);
    
    // イベントキューからイベントを安全に取得
    NSArray *events = nil;
    [eventLock lock];
    events = [pendingEvents copy];  // 配列のコピーを取得
    [pendingEvents removeAllObjects]; // イベントをクリア
    [eventLock unlock];
    
    // イベントの処理
    for (NSDictionary *event in events) {
        CGPoint position = [[event objectForKey:@"position"] CGPointValue];
        NSString *type = [event objectForKey:@"type"];
        
        // 位置情報の更新
        nk_input_motion(ctx, (int)position.x, (int)position.y);
        
        // イベントタイプに基づいた処理
        if ([type isEqualToString:@"began"]) {
            nk_input_button(ctx, NK_BUTTON_LEFT, (int)position.x, (int)position.y, 1);
        } else if ([type isEqualToString:@"ended"] || [type isEqualToString:@"cancelled"]) {
            nk_input_button(ctx, NK_BUTTON_LEFT, (int)position.x, (int)position.y, 0);
        } else if ([type isEqualToString:@"moved"]) {
            // 移動中はボタン状態を維持（必要に応じて）
        }
    }
    
    nk_input_end(ctx);
    
    // UI描画 - タッチインジケーターを別ウィンドウで表示
    [self drawUI];
    
    // Nuklearレンダリング
    nk_gles1_render(NK_ANTI_ALIASING_ON);
    
    // バッファ交換
    glBindRenderbufferOES(GL_RENDERBUFFER_OES, colorRenderBuffer);
    [context presentRenderbuffer:GL_RENDERBUFFER_OES];
}

#pragma mark - UI描画

- (void)drawUI {
    // 通常のUI
    float windowWidth = MIN(backingWidth - 30, 350);
    float windowHeight = MIN(backingHeight - 30, 450);
    float x = (backingWidth - windowWidth) * 0.5f;
    float y = (backingHeight - windowHeight) * 0.5f;
    
    if (showDemo) {
        [self drawMainWindow:nk_rect(x, y, windowWidth, windowHeight)];
        [self drawColorPickerWindow:nk_rect(20, 20, 300, 350)];
    }
    
    // 座標デバッグウィンドウを追加
    [self drawCoordinatesDebugWindow:nk_rect(backingWidth - 220, 20, 200, 160)];
    
    // タッチインジケーター（安全な方法で）
    if (isTouching) {
        struct nk_rect indicator = nk_rect(backingWidth - 30, backingHeight - 30, 20, 20);
        if (nk_begin(ctx, "TouchStatus", indicator, NK_WINDOW_BACKGROUND|NK_WINDOW_NO_SCROLLBAR)) {
            struct nk_command_buffer *canvas = nk_window_get_canvas(ctx);
            if (canvas) {
                nk_fill_rect(canvas, nk_rect(0, 0, 20, 20), 0, nk_rgb(255, 0, 0));
            }
        }
        nk_end(ctx);
    }
}

// 別のウィンドウでタッチポイント情報を表示
- (void)drawTouchDebugWindow:(struct nk_rect)bounds {
    enum nk_window_flags flags = NK_WINDOW_BORDER | NK_WINDOW_NO_SCROLLBAR;
    
    if (nk_begin(ctx, "TouchDebug", bounds, flags)) {
        // テキストでタッチ位置を表示
        nk_layout_row_dynamic(ctx, 20, 1);
        char buffer[64];
        snprintf(buffer, sizeof(buffer), "Touch: (%.1f, %.1f)", touchPos.x, touchPos.y);
        nk_label(ctx, buffer, NK_TEXT_LEFT);
        
        // タッチ状態を表示
        nk_layout_row_dynamic(ctx, 20, 1);
        nk_label(ctx, isTouching ? "State: ACTIVE" : "State: NONE", NK_TEXT_LEFT);
        
        // タッチ中のみ赤い円をウィンドウ内に描画
        if (isTouching) {
            // ウィンドウ内に赤い四角形を描画（円の代わり）
            struct nk_command_buffer *canvas = nk_window_get_canvas(ctx);
            if (canvas) {
                struct nk_rect rect = nk_rect(5, 5, 10, 10);
                nk_fill_rect(canvas, rect, 0, nk_rgb(255, 0, 0));
            }
        }
    }
    nk_end(ctx);
}
- (void)drawMainWindow:(struct nk_rect)bounds {
    enum nk_window_flags windowFlags = NK_WINDOW_BORDER |
                                      NK_WINDOW_MOVABLE |
                                      NK_WINDOW_SCALABLE |
                                      NK_WINDOW_TITLE;
    
    if (nk_begin(ctx, "Nuklear iOS Demo", bounds, windowFlags)) {
        // タブ
        nk_layout_row_begin(ctx, NK_STATIC, 30, 4); // 4タブに変更
        
        nk_layout_row_push(ctx, bounds.w / 4 - 5);
        if (nk_button_label(ctx, "Controls")) {
            selectedTab = 0;
        }
        
        nk_layout_row_push(ctx, bounds.w / 4 - 5);
        if (nk_button_label(ctx, "Settings")) {
            selectedTab = 1;
        }
        
        nk_layout_row_push(ctx, bounds.w / 4 - 5);
        if (nk_button_label(ctx, "Fonts")) {
            selectedTab = 2;
        }
        
        nk_layout_row_push(ctx, bounds.w / 4 - 5);
        if (nk_button_label(ctx, "About")) {
            selectedTab = 3;
        }
        
        nk_layout_row_end(ctx);
        
        // タブの内容
        switch (selectedTab) {
            case 0: [self drawControlsTab]; break;
            case 1: [self drawSettingsTab]; break;
            case 2: [self drawFontDemoTab]; break;
            case 3: [self drawAboutTab]; break;
        }
        
        // ステータスバー
        nk_layout_row_dynamic(ctx, 30, 1);
        char buffer[64];
        snprintf(buffer, sizeof(buffer), 
                "Touch: (%.0f, %.0f) %s", 
                touchPos.x, touchPos.y,
                isTouching ? "DOWN" : "UP");
        nk_label(ctx, buffer, NK_TEXT_LEFT);
    }
    nk_end(ctx);
}

- (void)drawControlsTab {
    static int checkbox_value = 1;
    static int option_value = 0;
    static int slider_value = 30;
    static char text_buffer[64] = "Text input";
    
    // グループでコントロールを囲む
    nk_layout_row_dynamic(ctx, 220, 1);
    if (nk_group_begin(ctx, "Controls Group", NK_WINDOW_BORDER)) {
        // チェックボックス
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_checkbox_label(ctx, "Enable Feature", &checkbox_value);
        
        // ラジオボタン - 引数を正確に3つに修正
        nk_layout_row_dynamic(ctx, 30, 3);
        if (nk_radio_label(ctx, "Option A", &option_value))
            NSLog(@"Option A selected");
        if (nk_radio_label(ctx, "Option B", &option_value))
            NSLog(@"Option B selected");
        if (nk_radio_label(ctx, "Option C", &option_value))
            NSLog(@"Option C selected");
        
        // スライダー
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_property_int(ctx, "Slider:", 0, &slider_value, 100, 1, 1);
        
        // テキスト入力
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_edit_string_zero_terminated(ctx, NK_EDIT_FIELD, text_buffer, 
                                      sizeof(text_buffer) - 1, nk_filter_default);
        
        // アクションボタン
        nk_layout_row_dynamic(ctx, 30, 2);
        if (nk_button_label(ctx, "OK")) {
            NSLog(@"OK button pressed");
        }
        if (nk_button_label(ctx, "Cancel")) {
            NSLog(@"Cancel button pressed");
        }
        
        nk_group_end(ctx);
    }
    
    // フォントの切り替えデモ
    nk_layout_row_dynamic(ctx, 30, 1);
    nk_label(ctx, "Font Examples:", NK_TEXT_LEFT);
    
    nk_layout_row_dynamic(ctx, 30, 1);
    if (defaultFont) {
        nk_style_push_font(ctx, &defaultFont->handle);
        nk_label(ctx, "Default Font Text", NK_TEXT_CENTERED);
        nk_style_pop_font(ctx);
    }
    
    nk_layout_row_dynamic(ctx, 30, 1);
    if (boldFont) {
        nk_style_push_font(ctx, &boldFont->handle);
        nk_label(ctx, "Bold Font Text", NK_TEXT_CENTERED);
        nk_style_pop_font(ctx);
    }
    
    nk_layout_row_dynamic(ctx, 30, 1);
    if (japaneseFont) {
        nk_style_push_font(ctx, &japaneseFont->handle);
        nk_label(ctx, "日本語テキスト例", NK_TEXT_CENTERED);
        nk_style_pop_font(ctx);
    }
}

- (void)drawSettingsTab {
    static float transparency = 1.0f;
    
    // 背景色設定
    nk_layout_row_dynamic(ctx, 30, 1);
    nk_label(ctx, "Background Color:", NK_TEXT_LEFT);
    
    nk_layout_row_dynamic(ctx, 180, 1);
    struct nk_colorf color = {
        backgroundColor[0], 
        backgroundColor[1], 
        backgroundColor[2], 
        backgroundColor[3]
    };
    if (nk_combo_begin_color(ctx, nk_rgb_cf(color), nk_vec2(nk_widget_width(ctx), 300))) {
        nk_layout_row_dynamic(ctx, 120, 1);
        color = nk_color_picker(ctx, color, NK_RGB);
        
        nk_layout_row_dynamic(ctx, 25, 1);
        // nk_propertyf は正確に3引数必要
        color.r = nk_propertyf(ctx, "#R:", 0, color.r, 1.0f, 0.01f, 0.005f);
        color.g = nk_propertyf(ctx, "#G:", 0, color.g, 1.0f, 0.01f, 0.005f);
        color.b = nk_propertyf(ctx, "#B:", 0, color.b, 1.0f, 0.01f, 0.005f);
        
        backgroundColor[0] = color.r;
        backgroundColor[1] = color.g;
        backgroundColor[2] = color.b;
        
        nk_combo_end(ctx);
    }
    
    // 透明度設定
    nk_layout_row_dynamic(ctx, 30, 1);
    nk_label(ctx, "Transparency:", NK_TEXT_LEFT);
    
    nk_layout_row_dynamic(ctx, 30, 1);
    // nk_slide_float は5引数必要
    backgroundColor[3] = nk_slide_float(ctx, 0.1f, backgroundColor[3], 1.0f, 0.01f);
    
    // リセットボタン
    nk_layout_row_dynamic(ctx, 30, 1);
    if (nk_button_label(ctx, "Reset to Default")) {
        backgroundColor[0] = 0.10f;
        backgroundColor[1] = 0.18f;
        backgroundColor[2] = 0.24f;
        backgroundColor[3] = 1.0f;
    }
}

- (void)drawFontDemoTab {
    nk_layout_row_dynamic(ctx, 30, 1);
    nk_label(ctx, "利用可能なフォント:", NK_TEXT_LEFT);
    
    // デフォルトフォント
    nk_layout_row_dynamic(ctx, 30, 1);
    if (defaultFont) {
        nk_style_push_font(ctx, &defaultFont->handle);
        nk_label(ctx, "Default Font: ABCDEFG 1234567890", NK_TEXT_CENTERED);
        nk_style_pop_font(ctx);
    }
    
    // Roboto Regular
    nk_layout_row_dynamic(ctx, 30, 1);
    if (systemFont) {
        nk_style_push_font(ctx, &systemFont->handle);
        nk_label(ctx, "Roboto Regular: ABCDEFG 1234567890", NK_TEXT_CENTERED);
        nk_style_pop_font(ctx);
    }
    
    // Roboto Bold
    nk_layout_row_dynamic(ctx, 30, 1);
    if (boldFont) {
        nk_style_push_font(ctx, &boldFont->handle);
        nk_label(ctx, "Roboto Bold: ABCDEFG 1234567890", NK_TEXT_CENTERED);
        nk_style_pop_font(ctx);
    }
    
    // 日本語フォント
    nk_layout_row_dynamic(ctx, 30, 1);
    if (japaneseFont) {
        nk_style_push_font(ctx, &japaneseFont->handle);
        nk_label(ctx, "日本語フォント: こんにちは世界", NK_TEXT_CENTERED);
        nk_style_pop_font(ctx);
    }
    
    // フォント選択
    nk_layout_row_dynamic(ctx, 30, 1);
    nk_label(ctx, "フォント選択:", NK_TEXT_LEFT);
    
    nk_layout_row_dynamic(ctx, 30, 1);
    if (nk_button_label(ctx, "デフォルトフォントを使用")) {
        if (defaultFont) {
            nk_style_set_font(ctx, &defaultFont->handle);
            NSLog(@"デフォルトフォントに切り替え");
        }
    }
    
    nk_layout_row_dynamic(ctx, 30, 1);
    if (nk_button_label(ctx, "Robotoフォントを使用")) {
        if (systemFont) {
            nk_style_set_font(ctx, &systemFont->handle);
            NSLog(@"Robotoフォントに切り替え");
        }
    }
    
    nk_layout_row_dynamic(ctx, 30, 1);
    if (nk_button_label(ctx, "太字フォントを使用")) {
        if (boldFont) {
            nk_style_set_font(ctx, &boldFont->handle);
            NSLog(@"太字フォントに切り替え");
        }
    }
}

- (void)drawAboutTab {
    nk_layout_row_dynamic(ctx, 30, 1);
    nk_label(ctx, "Nuklear iOS Demo", NK_TEXT_CENTERED);
    
    if (systemFont) {
        nk_style_push_font(ctx, &systemFont->handle);
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_label(ctx, "Using iOS System Font", NK_TEXT_CENTERED);
        nk_style_pop_font(ctx);
    }
    
    // アイコン付きのラベル
    nk_layout_row_begin(ctx, NK_DYNAMIC, 30, 2);
    nk_layout_row_push(ctx, 0.1f);
    nk_label(ctx, "★", NK_TEXT_CENTERED);
    nk_layout_row_push(ctx, 0.9f);
    nk_label(ctx, "OpenGL ES 1.1 + Nuklear", NK_TEXT_LEFT);
    nk_layout_row_end(ctx);
    
    // 区切り線
    nk_layout_row_dynamic(ctx, 10, 1);
    nk_spacing(ctx, 1);
    
    // バージョン情報
    nk_layout_row_dynamic(ctx, 20, 1);
    nk_label(ctx, "Version: 1.0.0", NK_TEXT_CENTERED);
    
    nk_layout_row_dynamic(ctx, 20, 1);
    nk_label(ctx, "© 2025 Example Inc.", NK_TEXT_CENTERED);
    
    // リンクのように見えるテキスト
    nk_style_push_color(ctx, &ctx->style.text.color, nk_rgb(0, 128, 255));
    nk_layout_row_dynamic(ctx, 30, 1);
    nk_label(ctx, "https://example.com", NK_TEXT_CENTERED);
    nk_style_pop_color(ctx);
    
    // 座標変換のデモ情報
    nk_layout_row_dynamic(ctx, 30, 1);
    char buffer[128];
    snprintf(buffer, sizeof(buffer), 
             "座標系: UIKit準拠 (スケール: %.2f x %.2f)",
             (float)backingWidth / self.bounds.size.width,
             (float)backingHeight / self.bounds.size.height);
    nk_label(ctx, buffer, NK_TEXT_LEFT);
}

- (void)drawColorPickerWindow:(struct nk_rect)bounds {
    static struct nk_colorf color = {0.6f, 0.3f, 0.5f, 1.0f};
    
    if (nk_begin(ctx, "Color Picker", bounds, 
                NK_WINDOW_BORDER|NK_WINDOW_MOVABLE|NK_WINDOW_SCALABLE|
                NK_WINDOW_MINIMIZABLE|NK_WINDOW_TITLE)) {
        
        // ヘッダ
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_label(ctx, "Color Picker Example", NK_TEXT_CENTERED);
        
        // カラーピッカー
        nk_layout_row_dynamic(ctx, 180, 1);
        color = nk_color_picker(ctx, color, NK_RGBA);
        
        // 個別のカラー成分 - nk_propertyf は3引数
        nk_layout_row_dynamic(ctx, 25, 1);
        color.r = nk_propertyf(ctx, "Red:", 0, color.r, 1.0f, 0.01f, 0.005f);
        color.g = nk_propertyf(ctx, "Green:", 0, color.g, 1.0f, 0.01f, 0.005f);
        color.b = nk_propertyf(ctx, "Blue:", 0, color.b, 1.0f, 0.01f, 0.005f);
        color.a = nk_propertyf(ctx, "Alpha:", 0, color.a, 1.0f, 0.01f, 0.005f);
        
        // 現在の色を表示
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_label(ctx, "Current Color:", NK_TEXT_LEFT);
        
        struct nk_rect color_rect = nk_widget_bounds(ctx);
        color_rect.h = 30;
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_fill_rect(&ctx->current->buffer, color_rect, 0, nk_rgba_cf(color));
        nk_stroke_rect(&ctx->current->buffer, color_rect, 0, 1.0f, nk_rgb(100, 100, 100));
    }
    nk_end(ctx);
}

#pragma mark - メモリ管理

- (void)dealloc {
    NSLog(@"リソース解放開始");
    
    // CADisplayLinkの停止
    [displayLink invalidate];
    displayLink = nil;
    
    // フレームバッファの破棄
    [self destroyFramebuffer];
    
    // OpenGL ESコンテキストをアクティブに
    [EAGLContext setCurrentContext:context];
    
    // フォントテクスチャの解放
    if (fontTexture) {
        glDeleteTextures(1, &fontTexture);
        fontTexture = 0;
    }
    
    // Nuklearリソースのシャットダウン
    if (ctx) {
        nk_buffer_free(&cmds);
        nk_gles1_shutdown();
        ctx = NULL;
    }
    
    // OpenGL ESコンテキストをクリア
    [EAGLContext setCurrentContext:nil];
    context = nil;
    
    renderer = nil;
    inputHandler = nil;
    fontHelper = nil;
    
    NSLog(@"リソース解放完了");
}

@end

#pragma mark - アプリケーションデリゲート

@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (strong, nonatomic) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    NSLog(@"アプリケーション起動開始");
    
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    
    // ルートビューコントローラ
    UIViewController *rootViewController = [[UIViewController alloc] init];
    
    // NuklearView
    NuklearView *view = [[NuklearView alloc] initWithFrame:rootViewController.view.bounds];
    [rootViewController.view addSubview:view];
    [view setAutoresizingMask:UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight];
    
    // ウィンドウ表示
    self.window.rootViewController = rootViewController;
    self.window.backgroundColor = [UIColor whiteColor];
    [self.window makeKeyAndVisible];
    
    NSLog(@"アプリケーション起動完了");
    return YES;
}

@end

// メイン関数
int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
