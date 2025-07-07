#import <UIKit/UIKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#import <MetalKit/MetalKit.h>
#import <CoreText/CoreText.h>

/*
 * 【iOSでの主な問題と対応・修正履歴】
 *
 * 1. テキスト入力（IME/日本語入力/仮想キーボード）
 *    - Metal描画上でNuklearのテキストボックスに直接入力できない
 *    - UIKeyInputのみではiOSのIME確定前の文字列や日本語変換に非対応
 *    - 仮想キーボードでの入力内容がNuklearバッファに即時反映されない
 *
 * 2. テキストボックスの位置・重なり
 *    - Metal描画の上にUITextFieldを重ねて表示しないとユーザーが編集できない
 *    - 仮想キーボード表示時にUITextFieldが隠れる問題
 *
 * 【iOS向け修正・追加・変更履歴】
 *
 * - 不可視UITextField方式から、Nuklearのテキストボックス位置にUITextFieldを重ねて表示する方式に変更
 * - drawUI内でnk_widget_boundsでテキストボックスの矩形を取得し、UITextFieldのframeを毎フレーム同期
 * - UITextField生成時にaddSubviewし、bringSubviewToFrontでMetal描画の上に表示
 * - UITextFieldのEditingChangedイベントでNuklearバッファに即時反映
 * - キーボード表示/非表示の通知（UIKeyboardWillShow/WillHide）を受けて、UITextFieldやビュー全体の位置を調整し、キーボードで隠れないように対応
 * - テキストボックスが非アクティブになったらUITextFieldをhiddenにし、内容をNuklearバッファに反映
 * - Metal座標系とUIView座標系の変換（contentScaleFactorで割る）を明示的に実装
 *
 * これにより、iOSのIME・日本語入力・仮想キーボード・カーソル・選択・確定など全ての機能がNuklear UI上で自然に動作するようになった。
 */

/*
 *    if (width <= 0 || height <= 0) {
        NSLog(@"[nk_metal_init] エラー: 無効なサイズ指定: %dx%d", width, height);
        return NULL;
    }
    
    // Nuklearコンテキストの初期化
    if (nk_init_default(&g_ctx, 0) != NK_SUCCESS) {
        NSLog(@"[nk_metal_init] エラー: Nuklearコンテキストの初期化に失敗しました");
        return NULL;
    }=======================================================================
 * Nuklear + Metal iOS実装
 *
 * このソースコードは軽量UIフレームワーク「Nuklear」とiOS Metal APIの統合を実現します。
 * macOS版Metal実装をベースに、iOS特有のタッチイベント処理などを追加しています。
 *
 * 【開発の流れと課題解決】
 * 
 * 1. macOS Metal版の開発
 *    - まずmacOS用のNuklear + Metal実装を作成
 *    - レンダリング問題（シェーダー、頂点フォーマット、座標変換）を解決
 *    - イベントキュー方式でマウス操作の同期問題を解決
 *
 * 2. iOS版への移植
 *    - macOSコードをベースにiOS固有の処理に変更
 *    - マウスイベントからタッチイベントへの変換
 *    - UIKitの座標系とNuklearの座標系の整合性確保
 *
 * 3. 重要な修正ポイント
 *    - AppDelegate/ViewControllerのライフサイクル管理
 *    - MTKViewとMTKViewDelegateの正確な実装
 *    - Metalコマンドバッファと描画処理の同期
 *    - Info.plistの設定修正（SceneDelegateの依存を削除）
 *    - デバッグログの追加によるトラブルシューティング強化
 *
 * 主な特徴:
 *
 * 1. マルチプラットフォーム対応
 *    - iOS/iPadOS向けメタルバックエンド実装
 *    - タッチ入力系のマウス入力への変換
 *    - 高DPI (Retina) ディスプレイのサポート
 *
 * 2. イベント処理アーキテクチャの改良
 *    - イベントキューによるスレッドセーフな実装
 *    - iOS特有のタッチハンドリング（began/moved/ended）
 *    - 座標系の正確な変換（UIKit→Metal→Nuklear）
 *
 * 3. Metal特化の最適化
 *    - 効率的なテクスチャ管理（R8Unormフォーマット）
 *    - ハイパフォーマンスなメタルレンダリングパイプライン
 *    - 適切なバッファ管理とリソース確保
 *
 * 4. iOS特有の実装
 *    - CADisplayLinkによるVSync同期
 *    - Metal用MTKViewの活用
 *    - システムフォント統合
 *
 * 【タッチ処理とイベント同期の課題】
 *
 * 1. イベントキュー方式の導入
 *    - タッチイベントが発生した時点で直接Nuklearに通知せず、キューに追加
 *    - NSMutableArrayとNSLockを使用してスレッドセーフなキューを実装
 *    - イベント情報（種類、位置、状態）をNSDictionaryに格納
 *
 * 2. タッチ入力からNuklearへの通知プロセス
 *    - touchesBegan: nk_input_button(ctx, NK_BUTTON_LEFT, x, y, 1)
 *    - touchesEnded: nk_input_button(ctx, NK_BUTTON_LEFT, x, y, 0)
 *    - touchesMoved: nk_input_motion(ctx, x, y)
 *    - タッチ座標はUIKit座標系からNuklear座標系に変換
 *
 * 3. スレッド間同期とロック
 *    - eventLockを使用してイベントキューへのアクセスを排他制御
 *    - [eventLock lock]と[eventLock unlock]でイベントの保護
 *    - pendingEventsの読み取り/書き込みはすべてロックで保護
 *
 * 4. レンダリングプロセスの最適化
 *    - コマンドバッファの完了ハンドラ追加によるデバッグ強化
 *    - 描画状態のロギングと監視
 *    - MTKViewの描画サイクルとNuklearの入力サイクルの同期
 *
 * 【解決した重要な問題点】
 *
 * 1. SceneDelegate依存の問題
 *    - Info.plistからUIApplicationSceneManifestを削除
 *    - 従来方式のAppDelegateベースのライフサイクル管理に変更
 *
 * 2. 描画されない問題
 *    - MTKViewDelegateの実装とself.delegateの正しい設定
 *    - ViewControllerでのビュー初期化タイミングの調整
 *    - コマンドバッファとドローアブルの適切なエラー処理
 *
 * 3. UIレスポンスの問題
 *    - タッチイベント処理時の座標変換精度向上
 *    - イベントタイプ（began/moved/ended）の明確な区別
 *    - 即時描画リクエストによる応答性向上
 *
 * この実装により、iOS上でもNuklear UIが正常に動作し、特にドラッグ操作や
 * ボタンクリックなどのインタラクションが適切に処理されます。macOSとiOS両方で
 * 一貫したユーザー体験を提供するクロスプラットフォーム実装を実現しました。
 * ================================================================================
 */

#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_FONT
// nk_draw_indexの型を明示的に定義
#ifndef nk_draw_index
    typedef uint16_t nk_draw_index;
#endif

#define NK_IMPLEMENTATION
#define NK_INCLUDE_FIXED_TYPES
#import "nuklear.h"
static char text[256] = "";
static int text_len = 0;
/**
 * Metal用 Nuklear バインディング構造体
 *
 * この構造体は、NuklearとMetal APIの橋渡しをする役割を持ち、
 * Nuklearの描画コマンドをMetalのレンダリングパイプラインに変換するために
 * 必要なすべてのリソースとステートを管理します。
 */
typedef struct nk_metal {
    id<MTLDevice> device;           // Metalデバイス（GPUへの論理的接続）
    id<MTLCommandQueue> commandQueue; // コマンドをGPUに送信するキュー
    id<MTLLibrary> library;         // コンパイル済みシェーダーライブラリ
    id<MTLRenderPipelineState> pipelineState; // レンダリングパイプライン状態
    id<MTLBuffer> vertexBuffer;     // 頂点データバッファ
    id<MTLBuffer> indexBuffer;      // インデックスバッファ
    NSUInteger maxVertices;         // 最大頂点数
    NSUInteger maxIndices;          // 最大インデックス数
    struct nk_buffer cmds;          // Nuklearコマンドバッファ
    struct nk_font_atlas *atlas;    // フォントアトラス
    struct nk_font *font;           // 使用フォント
    id<MTLTexture> font_tex;        // フォントテクスチャ
} nk_metal;
static nk_metal g_nk_metal = {0};

// Nuklear用コンテキスト
static struct nk_context g_ctx;

// Metal用 Nuklear 初期化
static struct nk_context *nk_metal_init(id<MTLDevice> device, int width, int height) {
    NSLog(@"[nk_metal_init] 初期化：幅=%d, 高さ=%d", width, height);
    
    if (!device) {
        NSLog(@"[nk_metal_init] エラー: Metalデバイスが提供されていません");
        return NULL;
    }
    
    if (width <= 0 || height <= 0) {
        NSLog(@"[nk_metal_init] ERROR: Invalid dimensions: %dx%d", width, height);
        return NULL;
    }
    
    // Nuklear コンテキストの初期化
    if (nk_init_default(&g_ctx, 0) == 0) {
        NSLog(@"[nk_metal_init] ERROR: Failed to initialize Nuklear context");
        return NULL;
    }

    g_nk_metal.device = device;
    g_nk_metal.commandQueue = [device newCommandQueue];
    g_nk_metal.maxVertices = 4096;
    g_nk_metal.maxIndices = 8192;
    // 頂点サイズ: 2 floats (pos) + 2 floats (uv) + 4 floats (color) = 8 floats = 32 bytes/vertex
    g_nk_metal.vertexBuffer = [device newBufferWithLength:g_nk_metal.maxVertices * sizeof(float) * 8 options:MTLResourceStorageModeShared];
    g_nk_metal.indexBuffer = [device newBufferWithLength:g_nk_metal.maxIndices * sizeof(uint16_t) options:MTLResourceStorageModeShared];

    /**
     * フォントアトラスの生成とMetalテクスチャ作成
     */
    struct nk_font_atlas *atlas = malloc(sizeof(struct nk_font_atlas));
    nk_font_atlas_init_default(atlas);
    nk_font_atlas_begin(atlas);
    struct nk_font *font = nk_font_atlas_add_default(atlas, 13.0f, 0);
    int font_w, font_h;
    // アルファチャンネルのみのフォーマットを使用（メモリ効率の良い形式）
    const void *image = nk_font_atlas_bake(atlas, &font_w, &font_h, NK_FONT_ATLAS_ALPHA8);
    // Metal側もR8Unormフォーマットを使用（単一チャンネル）
    MTLTextureDescriptor *texDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm width:font_w height:font_h mipmapped:NO];
    id<MTLTexture> font_tex = [device newTextureWithDescriptor:texDesc];
    MTLRegion region = {
        {0, 0, 0}, {font_w, font_h, 1}
    };
    // ALPHA8フォーマットなのでbytesPerRowは1バイト/ピクセル
    [font_tex replaceRegion:region mipmapLevel:0 withBytes:image bytesPerRow:font_w * 1];
    nk_font_atlas_end(atlas, nk_handle_ptr((__bridge void *)font_tex), 0);
    nk_style_set_font(&g_ctx, &font->handle);
    g_nk_metal.atlas = atlas;
    g_nk_metal.font = font;
    g_nk_metal.font_tex = font_tex;

    /**
     * Metal シェーダーライブラリの作成
     */
    NSError *error = nil;
    NSString *shaderSrc =
    @"using namespace metal;\n"
    "struct VertexIn { float2 pos [[attribute(0)]], uv [[attribute(1)]]; float4 color [[attribute(2)]]; };\n"
    "struct VertexOut { float4 pos [[position]]; float2 uv; float4 color; };\n"
    "vertex VertexOut v_main(VertexIn in [[stage_in]], constant float2 &viewportSize [[buffer(1)]]) {\n"
    "  VertexOut out;\n"
    "  // NDC座標変換：スクリーン座標を[-1,1]の範囲に正規化\n"
    "  // Nuklearは左上原点のピクセル座標を使用、Metalは[-1,1]の正規化デバイス座標が必要\n"
    "  float2 clipPos = in.pos / (viewportSize * 0.5) - 1.0;\n"
    "  // Metal座標系はY軸が下向きなので反転（OpenGLとは逆）\n"
    "  clipPos.y = -clipPos.y;\n"
    "  out.pos = float4(clipPos, 0, 1);\n"
    "  out.uv = in.uv;\n"
    "  out.color = in.color;\n"
    "  return out;\n"
    "}\n"
    // フォントテクスチャからアルファを抽出し、カラーと合成
    "fragment float4 f_main(VertexOut in [[stage_in]],\n"
    "  texture2d<float> tex [[texture(0)]],\n"
    "  sampler samp [[sampler(0)]]) {\n"
    "  // R8Unormフォーマットでは、テクスチャのrチャンネルがフォントの透明度を表す\n"
    "  float alpha = tex.sample(samp, in.uv).r;\n"
    "  return float4(in.color.rgb, in.color.a * alpha);\n"
    "}";
    g_nk_metal.library = [device newLibraryWithSource:shaderSrc options:nil error:&error];
    if (!g_nk_metal.library) { NSLog(@"Metalシェーダーのコンパイルエラー: %@", error); return NULL; }

    /**
     * Metal頂点ディスクリプタの設定
     */
    MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2; // pos
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;
    vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2; // uv
    vertexDescriptor.attributes[1].offset = sizeof(float) * 2;
    vertexDescriptor.attributes[1].bufferIndex = 0;
    vertexDescriptor.attributes[2].format = MTLVertexFormatFloat4; // color (RGBA)
    vertexDescriptor.attributes[2].offset = sizeof(float) * 4;
    vertexDescriptor.attributes[2].bufferIndex = 0;
    vertexDescriptor.layouts[0].stride = sizeof(float) * 8; // 2 floats (pos) + 2 floats (uv) + 4 floats (color)
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    /**
     * Metal レンダリングパイプライン設定
     */
    MTLRenderPipelineDescriptor *pipelineDesc = [[MTLRenderPipelineDescriptor alloc] init];
    pipelineDesc.vertexFunction = [g_nk_metal.library newFunctionWithName:@"v_main"];
    pipelineDesc.fragmentFunction = [g_nk_metal.library newFunctionWithName:@"f_main"];
    pipelineDesc.vertexDescriptor = vertexDescriptor;
    pipelineDesc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    pipelineDesc.colorAttachments[0].blendingEnabled = YES;
    pipelineDesc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    pipelineDesc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    pipelineDesc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    pipelineDesc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    pipelineDesc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    pipelineDesc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g_nk_metal.pipelineState = [device newRenderPipelineStateWithDescriptor:pipelineDesc error:&error];
    if (!g_nk_metal.pipelineState) { NSLog(@"Metalパイプラインエラー: %@", error); return NULL; }

    // コマンドバッファ初期化
    nk_buffer_init_default(&g_nk_metal.cmds);

    return &g_ctx;
}

// Metal用 Nuklear 描画
static void nk_metal_render(struct nk_context *ctx, id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable, int width, int height) {
    if (!ctx || !commandBuffer || !drawable || width <= 0 || height <= 0) {
        NSLog(@"[nk_metal_render] エラー: パラメータが無効です");
        return;
    }
    
    // パイプラインステート確認
    if (!g_nk_metal.pipelineState) {
        NSLog(@"[nk_metal_render] エラー: パイプライン状態がnilです");
        return;
    }
    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = drawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.18, 0.24, 1.0);

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];
    [encoder setRenderPipelineState:g_nk_metal.pipelineState];

    /**
     * NuklearコマンドバッファをMetalバッファに変換・転送・描画
     */
    struct nk_buffer vbuf, ibuf;
    nk_buffer_init_default(&vbuf);
    nk_buffer_init_default(&ibuf);

    // Nuklear頂点レイアウト設定
    static const struct nk_draw_vertex_layout_element vertex_layout[] = {
        {NK_VERTEX_POSITION, NK_FORMAT_FLOAT, 0},              // position (float x, y) - オフセット 0
        {NK_VERTEX_TEXCOORD, NK_FORMAT_FLOAT, 8},              // uv (float u, v) - オフセット 8 (2 floats * 4 bytes)
        {NK_VERTEX_COLOR, NK_FORMAT_R32G32B32A32_FLOAT, 16},   // color (float r,g,b,a) - オフセット 16 (4 floats * 4 bytes)
        {NK_VERTEX_LAYOUT_END}
    };
    struct nk_convert_config config = {0};
    config.vertex_layout = vertex_layout;
    config.vertex_size = sizeof(float) * 8;  // 2 floats for pos + 2 floats for uv + 4 floats for color
    config.vertex_alignment = 4;  // 標準的なアライメント
    config.null = (struct nk_draw_null_texture){0};
    config.circle_segment_count = 22;
    config.curve_segment_count = 22;
    config.arc_segment_count = 22;
    config.global_alpha = 1.0f;
    config.shape_AA = NK_ANTI_ALIASING_ON;
    config.line_AA = NK_ANTI_ALIASING_ON;

    struct nk_draw_command *cmd;
    nk_buffer_clear(&g_nk_metal.cmds);
    int convert_result = nk_convert(ctx, &g_nk_metal.cmds, &vbuf, &ibuf, &config);
    if (convert_result != NK_CONVERT_SUCCESS) {
        NSLog(@"[nk_metal_render] エラー: nk_convertがコード %d で失敗しました", convert_result);
        nk_buffer_free(&vbuf);
        nk_buffer_free(&ibuf);
        return;
    }

    // 頂点データとインデックスデータをコピー
    void *vertexData = nk_buffer_memory(&vbuf);
    void *indexData = nk_buffer_memory(&ibuf);
    NSUInteger vsize = nk_buffer_total(&vbuf);
    NSUInteger isize = nk_buffer_total(&ibuf);
    memcpy(g_nk_metal.vertexBuffer.contents, vertexData, vsize);
    memcpy(g_nk_metal.indexBuffer.contents, indexData, isize);

    // バッファをバインド
    [encoder setVertexBuffer:g_nk_metal.vertexBuffer offset:0 atIndex:0];
    
    // ビューポートサイズをシェーダーに渡す
    float viewportSize[2] = {(float)width, (float)height};
    [encoder setVertexBytes:viewportSize length:sizeof(viewportSize) atIndex:1];

    // フォントテクスチャをfragment shaderにバインド
    [encoder setFragmentTexture:g_nk_metal.font_tex atIndex:0];

    // サンプラー設定
    static id<MTLSamplerState> sampler = nil;
    if (!sampler) {
        MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
        sampDesc.minFilter = MTLSamplerMinMagFilterLinear;
        sampDesc.magFilter = MTLSamplerMinMagFilterLinear;
        sampler = [g_nk_metal.device newSamplerStateWithDescriptor:sampDesc];
    }
    [encoder setFragmentSamplerState:sampler atIndex:0];

    // Nuklearの描画コマンドリストの処理
    uint16_t offset = 0;
    nk_draw_foreach(cmd, ctx, &g_nk_metal.cmds) {
        if (!cmd->elem_count) {
            continue;
        }
              
        if (cmd->texture.ptr) {
            id<MTLTexture> tex = (__bridge id<MTLTexture>)cmd->texture.ptr;
            [encoder setFragmentTexture:tex atIndex:0];
        } else {
            [encoder setFragmentTexture:g_nk_metal.font_tex atIndex:0];
        }
        // サンプラーも毎回明示的にバインド
        [encoder setFragmentSamplerState:sampler atIndex:0];
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:cmd->elem_count
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:g_nk_metal.indexBuffer
                     indexBufferOffset:offset * sizeof(uint16_t)]; // uint16_tを使用
        offset += cmd->elem_count;
    }

    nk_buffer_free(&vbuf);
    nk_buffer_free(&ibuf);

    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
}

// Metal用 Nuklear リソース解放
static void nk_metal_shutdown(void) {
    g_nk_metal.device = nil;
    g_nk_metal.commandQueue = nil;
    g_nk_metal.library = nil;
    g_nk_metal.pipelineState = nil;
    g_nk_metal.vertexBuffer = nil;
    g_nk_metal.indexBuffer = nil;
    nk_buffer_free(&g_nk_metal.cmds);
}

// iOS用のMTKViewを継承したNuklearView
@interface NuklearMetalView : MTKView <MTKViewDelegate, UITextFieldDelegate>
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, assign) struct nk_context *nk_ctx;
@property (nonatomic, assign) BOOL isRendering;

// イベントキュー関連
@property (nonatomic, strong) NSMutableArray *pendingEvents;
@property (nonatomic, strong) NSLock *eventLock;
@property (nonatomic, assign) BOOL needsRedraw;
@property (nonatomic, assign) CGPoint touchPos;
@property (nonatomic, assign) BOOL isTouching;

// UIステート
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
// 不可視UITextField
@property (nonatomic, strong) UITextField *hiddenTextField;

@property (nonatomic, strong) UITextField *nkTextField;
@property (nonatomic, assign) BOOL nkTextFieldActive;
@property (nonatomic, strong) NSString *nkTextFieldBuffer;
@end
@implementation NuklearMetalView
- (void)keyboardWillShow:(NSNotification *)notification {
    CGRect kbFrame = [notification.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    kbFrame = [self convertRect:kbFrame fromView:nil];
    CGRect tfFrame = self.nkTextField.frame;
    if (CGRectIntersectsRect(tfFrame, kbFrame)) {
        CGFloat offset = CGRectGetMaxY(tfFrame) - kbFrame.origin.y + 10;
        if (offset > 0) {
            [UIView animateWithDuration:0.3 animations:^{
                self.transform = CGAffineTransformMakeTranslation(0, -offset);
            }];
        }
    }
}

- (void)keyboardWillHide:(NSNotification *)notification {
    [UIView animateWithDuration:0.3 animations:^{
        self.transform = CGAffineTransformIdentity;
    }];
}


- (instancetype)initWithFrame:(CGRect)frame {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (self = [super initWithFrame:frame device:device]) {
        self.clearColor = MTLClearColorMake(0.1, 0.18, 0.24, 1.0);
        self.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
        self.framebufferOnly = YES;
        CGFloat scale = [UIScreen mainScreen].scale;
        self.contentScaleFactor = scale;
        _pendingEvents = [NSMutableArray array];
        _eventLock = [[NSLock alloc] init];
        _needsRedraw = YES;
        _touchPos = CGPointZero;
        _isTouching = NO;
        _width = (int)(frame.size.width * scale);
        _height = (int)(frame.size.height * scale);
        _commandQueue = [device newCommandQueue];
        _nk_ctx = nk_metal_init(device, _width, _height);
        if (!_nk_ctx) {
            NSLog(@"エラー: Nuklear Metalの初期化に失敗しました");
            return nil;
        }
        _isRendering = NO;
        self.enableSetNeedsDisplay = YES;
        self.paused = NO;
        self.delegate = self;
        NSLog(@"NuklearMetalViewの初期化が完了しました");
        self.delegate = nil;
        self.enableSetNeedsDisplay = YES;
        self.paused = NO;
        NSLog(@"NuklearMetalView initialization complete");
        // --- ここから不可視UITextFieldの追加 ---
        self.hiddenTextField = [[UITextField alloc] initWithFrame:CGRectZero];
        self.hiddenTextField.delegate = self;
        self.hiddenTextField.hidden = YES;
        [self addSubview:self.hiddenTextField];
        [self.hiddenTextField addTarget:self action:@selector(hiddenTextFieldChanged:) forControlEvents:UIControlEventEditingChanged];
        // --- ここまで追加 ---
                // キーボード通知の登録
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(keyboardWillShow:)
                                                     name:UIKeyboardWillShowNotification
                                                   object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(keyboardWillHide:)
                                                     name:UIKeyboardWillHideNotification
                                                   object:nil];
    }
    return self;
}
// UITextFieldの内容が変わったらNuklearバッファに反映
- (void)hiddenTextFieldChanged:(UITextField *)textField {
    // Nuklearのバッファにコピー
    strncpy(text, [textField.text UTF8String], sizeof(text)-1);
    text[sizeof(text)-1] = '\\0';
    text_len = (int)strlen(text);
}
- (BOOL)textField:(UITextField *)textField shouldChangeCharactersInRange:(NSRange)range replacementString:(NSString *)string {
    NSUInteger newLength = textField.text.length - range.length + string.length;
    return (newLength <= 255); // 例: 256バイト未満なら許可
}
#pragma mark - UIKeyInput

- (BOOL)hasText {
    return YES;
}

- (void)insertText:(NSString *)textInput {
    struct nk_context *ctx = self.nk_ctx;
    for (NSUInteger i = 0; i < textInput.length; ++i) {
        unichar c = [textInput characterAtIndex:i];
        nk_input_unicode(ctx, c);
    }
}

- (void)deleteBackward {
    struct nk_context *ctx = self.nk_ctx;
    nk_input_key(ctx, NK_KEY_BACKSPACE, 1);
    nk_input_key(ctx, NK_KEY_BACKSPACE, 0);
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}
#pragma mark - 座標変換

// UIKit座標からNuklear座標に変換
- (CGPoint)convertToNuklearCoordinates:(CGPoint)point {
    /**
     * タッチ座標変換処理
     * - UIKit座標系からNuklear/Metal座標系への変換
     * - スケーリング適用（Retinaディスプレイ対応）
     * - Y軸反転の調整
     *
     * 注意点：
     * 1. UIKitは左上原点
     * 2. Nuklearも左上原点
     * 3. Metalは起点は左下だが、バーテックスシェーダで座標変換される
     * 4. イベント処理では、Nuklear座標系に合わせる必要がある
     */
    CGFloat scale = self.contentScaleFactor;
    
    // UIKit → Nuklear座標変換
    // 両方とも左上原点なのでY軸反転は必要なし、スケーリングのみ適用
    CGPoint result = CGPointMake(
        point.x * scale,
        point.y * scale
    );
    return result;
}

#pragma mark - イベント処理

// イベントキューに追加
- (void)queueEvent:(NSDictionary *)event {
    /**
     * イベントキュー処理
     * - スレッドセーフにイベントをキューに追加
     * - _needsRedrawフラグを設定して再描画を要求
     * - 即時描画をメインスレッドに要求してUI応答性を向上
     */
    [_eventLock lock];
    [_pendingEvents addObject:event];
    _needsRedraw = YES;
    [_eventLock unlock];
    
    // メインスレッドで即時描画を要求
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setNeedsDisplay];
    });
}

// タッチ開始
- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    /**
     * タッチ開始処理
     * - iOSのタッチ開始 = Nuklearのマウスボタン押下
     * - 明示的に "began" タイプを設定してイベントをキューに追加
     * - タッチ状態を追跡するフラグをON
     */
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self];
    CGPoint nuklearPoint = [self convertToNuklearCoordinates:point];
    
    _touchPos = nuklearPoint;
    _isTouching = YES;
    
    [self queueEvent:@{
        @"type": @"began",
        @"position": [NSValue valueWithCGPoint:nuklearPoint]
    }];
    
    NSLog(@"タッチ開始: 座標(%.1f, %.1f)", nuklearPoint.x, nuklearPoint.y);
}

// タッチ移動
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self];
    CGPoint nuklearPoint = [self convertToNuklearCoordinates:point];
    
    _touchPos = nuklearPoint;
    
    [self queueEvent:@{
        @"type": @"moved",
        @"position": [NSValue valueWithCGPoint:nuklearPoint]
    }];
}

// タッチ終了
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    /**
     * タッチ終了処理
     * - iOSのタッチ終了 = Nuklearのマウスボタン解放
     * - 明示的に "ended" タイプを設定
     * - タッチ状態フラグをOFF（重要: これがないとドラッグ状態が維持されてしまう）
     */
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self];
    CGPoint nuklearPoint = [self convertToNuklearCoordinates:point];
    
    _touchPos = nuklearPoint;
    _isTouching = NO;  // タッチ状態を確実にリセット
    
    [self queueEvent:@{
        @"type": @"ended",
        @"position": [NSValue valueWithCGPoint:nuklearPoint]
    }];
    
    NSLog(@"タッチ終了: 座標(%.1f, %.1f)", nuklearPoint.x, nuklearPoint.y);
}

// タッチキャンセル
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    /**
     * タッチキャンセル処理
     * - システムによるタッチのキャンセル（通話着信など）
     * - 解放処理と同様にボタンをリリース状態に設定
     */
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self];
    CGPoint nuklearPoint = [self convertToNuklearCoordinates:point];
    
    // タッチ状態を確実にリセット
    _isTouching = NO;
    
    // 明示的にキャンセルイベントをキューに追加
    [self queueEvent:@{
        @"type": @"cancelled",
        @"position": [NSValue valueWithCGPoint:nuklearPoint]
    }];
}

#pragma mark - MTKViewDelegate メソッド

// サイズ変更対応
- (void)mtkView:(MTKView *)view drawableSizeWillChange:(CGSize)size {
    // サイズの更新
    _width = (int)size.width;
    _height = (int)size.height;
    
    NSLog(@"Drawable size changed to %dx%d", _width, _height);
}

// メインレンダリングメソッド（MTKViewDelegate）
- (void)drawInMTKView:(MTKView *)view {
    NSLog(@"drawInMTKView called"); 
    [self drawRect:view.bounds];
}

// メインレンダリングメソッド
- (void)drawRect:(CGRect)rect {
    if (self.isRendering) {
        return;
    }
    self.isRendering = YES;
    
    @autoreleasepool {
        /**
         * Nuklear入力処理とレンダリング
         * - スレッドセーフにイベントを取得
         * - nk_input_begin/endで入力処理をラップ
         * - 各イベントタイプに応じた適切な入力通知
         */
        nk_input_begin(_nk_ctx);
        
        // イベントキューからイベントを安全に取得
        NSArray *events;
        [_eventLock lock];
        events = [_pendingEvents copy];
        [_pendingEvents removeAllObjects];
        [_eventLock unlock];
        
        // イベントの処理
        for (NSDictionary *event in events) {
            CGPoint position = [event[@"position"] CGPointValue];
            NSString *type = event[@"type"];
            
            // 位置情報の更新
            nk_input_motion(_nk_ctx, (int)position.x, (int)position.y);
            
            // イベントタイプに基づいた処理
            if ([type isEqualToString:@"began"]) {
                nk_input_button(_nk_ctx, NK_BUTTON_LEFT, (int)position.x, (int)position.y, 1);
            }
            else if ([type isEqualToString:@"ended"] || [type isEqualToString:@"cancelled"]) {
                nk_input_button(_nk_ctx, NK_BUTTON_LEFT, (int)position.x, (int)position.y, 0);
            }
            else if ([type isEqualToString:@"moved"]) {
                // 移動中はボタン状態を維持（必要に応じて）
            }
        }
        
        nk_input_end(_nk_ctx);
        
        // UI描画
        [self drawUI];
        
        // ドローアブルの取得とレンダリング
        id<CAMetalDrawable> drawable = [self currentDrawable];
        if (!drawable) {
            NSLog(@"Error: Failed to get Metal drawable");
            self.isRendering = NO;
            return;
        }
        
        id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];
        if (!commandBuffer) {
            NSLog(@"Error: Failed to create command buffer");
            self.isRendering = NO;
            return;
        }
        
//        NSLog(@"Rendering with drawable: %@ and command buffer: %@", drawable, commandBuffer);
        
        // レンダリング実行
  //      NSLog(@"Calling nk_metal_render with width=%d, height=%d", _width, _height);
        nk_metal_render(_nk_ctx, commandBuffer, drawable, _width, _height);
        
        // コマンドバッファをコミットして実行
        [commandBuffer addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
//            NSLog(@"Command buffer execution completed with status: %lu", (unsigned long)buffer.status);
        }];
        [commandBuffer commit];
        
        // 状態のクリア
        nk_clear(_nk_ctx);
    }
    
    self.isRendering = NO;
}
- (void)nkTextFieldEditingChanged:(UITextField *)textField {
    self.nkTextFieldBuffer = textField.text;
    [self setNeedsDisplay]; // 必要ならNuklear再描画
}
// Nuklear UIの描画
- (void)drawUI {
    struct nk_context *ctx = _nk_ctx;
    if (!ctx) return;

    // メインウィンドウ
    if (nk_begin(ctx, "Nuklear iOS Demo", nk_rect(50, 50, self.width - 100, self.height - 100),
                NK_WINDOW_BORDER|NK_WINDOW_MOVABLE|NK_WINDOW_SCALABLE|NK_WINDOW_TITLE))
    {
        // 静的な変数
        static int property = 20;
        static int option = 1;
        static float slider = 0.5f;
        static struct nk_colorf color = {0.5f, 0.3f, 0.4f, 1.0f};

        // テキストバッファ（NuklearとUITextFieldで同期）
        if (!self.nkTextFieldBuffer) self.nkTextFieldBuffer = @"";
        static int was_active = 0;

        // タイトル
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_label(ctx, "Nuklear + UITextField Widget", NK_TEXT_CENTERED);

        // ボタン
        nk_layout_row_static(ctx, 30, 2, 80);
        if (nk_button_label(ctx, "Button 1")) {
            NSLog(@"Button 1 pressed!");
        }
        if (nk_button_label(ctx, "Button 2")) {
            NSLog(@"Button 2 pressed!");
        }

        // オプション
        nk_layout_row_dynamic(ctx, 30, 2);
        if (nk_option_label(ctx, "Option 1", option == 1)) option = 1;
        if (nk_option_label(ctx, "Option 2", option == 2)) option = 2;

        // プロパティ
        nk_layout_row_dynamic(ctx, 25, 1);
        nk_property_int(ctx, "Property:", 0, &property, 100, 1, 1);

        // スライダー
        nk_layout_row_dynamic(ctx, 25, 1);
        nk_label(ctx, "Slider:", NK_TEXT_LEFT);
        nk_layout_row_dynamic(ctx, 25, 1);
        slider = nk_slide_float(ctx, 0, slider, 1.0f, 0.01f);

        // カラーピッカー
        nk_layout_row_dynamic(ctx, 150, 1);
        color = nk_color_picker(ctx, color, NK_RGB);

        // --- テキストボックスウィジェット ---
        nk_layout_row_dynamic(ctx, 30, 1);
        nk_label(ctx, "テキストボックスに入力:", NK_TEXT_LEFT);
        nk_layout_row_dynamic(ctx, 30, 1);

        // Nuklearバッファ
        char buf[256];
        strncpy(buf, [self.nkTextFieldBuffer UTF8String], sizeof(buf)-1);
        buf[sizeof(buf)-1] = '\0';
        int dummy_len = (int)strlen(buf);

        // Nuklearテキストボックスの描画とアクティブ判定
        struct nk_rect widget_rect = nk_widget_bounds(ctx);
        enum nk_edit_flags edit_flags = nk_edit_string(ctx, NK_EDIT_FIELD|NK_EDIT_CLIPBOARD, buf, &dummy_len, 256, nk_filter_default);

        // UITextFieldの表示・非表示・同期
        if ((edit_flags & NK_EDIT_ACTIVE) && !was_active) {
            if (!self.nkTextField) {
                self.nkTextField = [[UITextField alloc] initWithFrame:CGRectZero];
                self.nkTextField.delegate = self;
                self.nkTextField.borderStyle = UITextBorderStyleRoundedRect;
                [self.nkTextField addTarget:self action:@selector(nkTextFieldEditingChanged:) forControlEvents:UIControlEventEditingChanged];
                [self addSubview:self.nkTextField];
            }
            [self bringSubviewToFront:self.nkTextField];
            self.nkTextField.text = self.nkTextFieldBuffer ?: @"";
            self.nkTextField.hidden = NO;
            self.nkTextFieldActive = YES;
            [self.nkTextField becomeFirstResponder];
        }
        if (!(edit_flags & NK_EDIT_ACTIVE) && was_active) {
            if (self.nkTextField) {
                [self.nkTextField resignFirstResponder];
                self.nkTextField.hidden = YES;
                self.nkTextFieldActive = NO;
                self.nkTextFieldBuffer = self.nkTextField.text;
            }
        }
        was_active = (edit_flags & NK_EDIT_ACTIVE) ? 1 : 0;

        // 毎フレームframeを同期（Metal座標→UIView座標変換）
        if (self.nkTextField && self.nkTextFieldActive) {
            CGFloat scale = self.contentScaleFactor;
            CGRect tfFrame = CGRectMake(widget_rect.x / scale, widget_rect.y / scale, widget_rect.w / scale, widget_rect.h / scale);
            self.nkTextField.frame = tfFrame;
            [self bringSubviewToFront:self.nkTextField];
        }

        // タッチ座標表示（デバッグ用）
        nk_layout_row_dynamic(ctx, 25, 1);
        char buffer[128];
        snprintf(buffer, sizeof(buffer), "Touch: (%.0f, %.0f)", self.touchPos.x, self.touchPos.y);
        nk_label(ctx, buffer, NK_TEXT_LEFT);

        // 画面サイズ情報
        nk_layout_row_dynamic(ctx, 25, 1);
        snprintf(buffer, sizeof(buffer), "Screen: %dx%d, Scale: %.1f",
                 self.width, self.height, self.contentScaleFactor);
        nk_label(ctx, buffer, NK_TEXT_LEFT);
    }
    nk_end(ctx);
}

- (void)dealloc {
    nk_free(_nk_ctx);
    nk_metal_shutdown();
}

@end

/**
 * iOSアプリのメインビューコントローラー
 */
@interface ViewController : UIViewController
@property (nonatomic, strong) NuklearMetalView *nuklearView;
@property (nonatomic, strong) UITextField *nkTextField;
@property (nonatomic, assign) BOOL nkTextFieldActive;
@property (nonatomic, strong) NSString *nkTextFieldBuffer;
@end

@implementation ViewController

- (void)loadView {
    // ルートビューを作成
    self.view = [[UIView alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.view.backgroundColor = [UIColor darkGrayColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // ビューのサイズを確認
    NSLog(@"View bounds: %@", NSStringFromCGRect(self.view.bounds));
    
    // NuklearMetalViewのセットアップ
    self.nuklearView = [[NuklearMetalView alloc] initWithFrame:self.view.bounds];
    self.nuklearView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.nuklearView];
    
    // ビューを可視化（デバッグ用）
    self.nuklearView.backgroundColor = [UIColor redColor];
    
    // ビューの表示状態を確保
    [self.nuklearView setNeedsDisplay];
    
    NSLog(@"ViewController loaded with NuklearMetalView: %@", self.nuklearView);
}

@end

/**
 * アプリデリゲート
 */
@interface AppDelegate : UIResponder <UIApplicationDelegate>
@property (nonatomic, strong) UIWindow *window;
@end

@implementation AppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    // ウィンドウの作成と設定
    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor = [UIColor blackColor];
    
    // ViewControllerの初期化と設定
    ViewController *viewController = [[ViewController alloc] init];
    self.window.rootViewController = viewController;
    
    // ウィンドウの表示
    [self.window makeKeyAndVisible];
    
    NSLog(@"Application launched: window created and made visible");
    return YES;
}

@end

/**
 * メイン関数
 */
int main(int argc, char * argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([AppDelegate class]));
    }
}
