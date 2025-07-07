#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>

/*
 * ================================================================================
 * Nuklear + Metal 統合アプリケーション
 *
 * このソースコードは軽量Nuklear UIフレームワークとmacOS Metal APIの統合を示しています。
 *
 * 修正履歴と解決された問題:
 *
 * 【レンダリング関連の修正】
 *
 * 1. フォントテクスチャフォーマットの修正
 *    - RGBA32フォントベイキングからA8（アルファチャンネルのみ）に変更
 *    - これによりシェーダー処理が簡素化され、メモリ効率が向上
 *
 * 2. 頂点フォーマットの一致
 *    - Nuklearの頂点データとMetalの頂点ディスクリプタのレイアウトを統一
 *    - 色情報をR8G8B8A8（バイト配列）からfloat4に変更
 *
 * 3. 座標変換の修正
 *    - スクリーン座標からNDC(-1,1)座標への正しい変換を追加
 *    - Metal座標系はY軸が下向きなのでシェーダーでY軸を反転
 *
 * 4. メモリレイアウトの整合性
 *    - ストライド値とオフセットを正確に計算し、バイトアラインメントの問題を解決
 *
 * 5. エラー検出の強化
 *    - 各初期化ステップでのnullチェックとエラーチェックを追加
 *    - デバッグを容易にするための詳細なロギング
 *
 * 【マウスイベント処理の修正】
 *
 * 6. イベントキュー方式の導入
 *    - マウスイベントを直接処理せず、スレッドセーフなキューに格納
 *    - NSMutableArrayとNSLockを使用してスレッド間の同期問題を解決
 *    - イベントはNSDictionaryとして保存（種類・位置・ボタン状態）
 *
 * 7. 座標変換の改善
 *    - macOSの座標系（左下原点）からNuklear座標系（左上原点）への変換
 *    - Y座標を反転：result.y = _height - point.y
 *    - 高DPIディスプレイ対応のためのスケーリング適用
 *
 * 8. レンダリングサイクルでのイベント処理
 *    - render()メソッド内でキューからイベントを取り出し一括処理
 *    - mouseMove/mouseDrag → nk_input_motion()
 *    - mouseDown → nk_input_button(..., 1)
 *    - mouseUp → nk_input_button(..., 0)
 *
 * 9. 即時描画リクエストの実装
 *    - イベント発生時にdispatch_asyncでメインスレッドに描画要求
 *    - UI応答性の向上
 *
 * 10. マウストラッキングの設定
 *    - setAcceptsMouseMovedEvents:YESでマウス移動イベントを有効化
 *    - NSTrackingAreaでマウスの入退出を検知
 *
 * Metal描画とイベント処理の主な注意点:
 * - 頂点フォーマットとシェーダ入力は完全に一致する必要がある
 * - macOSではイベント処理とレンダリングが別スレッドで実行される（Windowsとは異なる）
 * - スレッド間の適切な同期が必要（ロック、キュー、メインスレッド実行等）
 * - コマンドバッファ、ドローアブル、レンダーパスの正しいタイミングでの作成と解放
 * - Metal APIは非同期で動作するため、リソース管理に注意
 * - 高解像度ディスプレイ対応のためのスケーリングファクター考慮
 * ================================================================================
 */

/*
 *
 * 2. 頂点フォーマットの一致
 *    - Nuklearの頂点データレイアウトとMetalの頂点ディスクリプタを統一
 *    - 色情報をR8G8B8A8（バイト単位）からfloat4に変更
 *
 * 3. 座標変換の修正
 *    - スクリーン座標からNDC(-1,1)座標への正しい変換を追加
 *    - Metal座標系はY軸が下向きなので、シェーダーでY軸を反転
 *
 * 4. メモリレイアウトの整合性
 *    - ストライド値とオフセットを正確に計算し、バイトアラインメント問題を解決
 *
 * 5. エラー検出の強化
 *    - 各初期化ステップでのnull/エラーチェックを追加
 *    - 詳細なログ出力でデバッグを容易に
 *
 * Metal描画時の主な注意点:
 * - 頂点フォーマットとシェーダ入力は完全に一致する必要がある
 * - コマンドバッファ、ドローアブル、レンダーパスの正しいタイミングでの作成と解放
 * - Metal APIは非同期で動作するため、リソース管理に注意
 * - 高解像度ディスプレイ対応のためのスケーリングファクター考慮
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
#import "nuklear.h"

/**
 * Metal用 Nuklear バインディング構造体
 *
 * この構造体は、NuklearとMetal APIの橋渡しをする役割を持ち、
 * Nuklearの描画コマンドをMetalのレンダリングパイプラインに変換するために
 * 必要なすべてのリソースとステートを管理します。
 *
 * 主なコンポーネント:
 * - Metal基本オブジェクト (デバイス、コマンドキュー、ライブラリ)
 * - レンダリングパイプライン状態
 * - 頂点/インデックスバッファ
 * - Nuklearのコマンドおよびフォントリソース
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
    NSLog(@"[nk_metal_init] Initializing with width=%d, height=%d", width, height);
    
    if (!device) {
        NSLog(@"[nk_metal_init] ERROR: No Metal device provided");
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
     *
     * 重要なポイント:
     * 1. Nuklearフォントをアルファチャンネルのみ(NK_FONT_ATLAS_ALPHA8)でベイク
     *    - メモリ効率が良く、フォントレンダリングに最適
     *    - 元のRGBA32よりも1/4のメモリ使用量
     *
     * 2. Metal側では対応するR8Unormフォーマットを使用
     *    - シングルチャンネルテクスチャとして効率的に扱える
     *    - フラグメントシェーダーでRチャンネルのみを読み取り
     *
     * 3. bytesPerRowの正確な計算
     *    - ALPHA8では1バイト/ピクセル
     *    - RGBA32では4バイト/ピクセル（元のコードの問題点）
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
    // --- ここまで ---

    /**
     * Metal シェーダーライブラリの作成
     *
     * ここでの主要なポイント:
     * 1. 頂点シェーダー
     *    - スクリーン座標からNDC座標(-1,1)への変換
     *    - Y軸の反転（Metal座標系はY軸が下向き、OpenGLとは逆）
     *    - ビューポートサイズをバッファとして受け取る設計
     *
     * 2. フラグメントシェーダー
     *    - R8Unormテクスチャからアルファ値を抽出
     *    - 頂点カラーとフォントアルファの合成
     *
     * 3. 頂点構造
     *    - 頂点フォーマットはMetalの頂点ディスクリプタと完全に一致する必要がある
     *    - 属性インデックスによるバインディング
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
    if (!g_nk_metal.library) { NSLog(@"Metal shader compile error: %@", error); return NULL; }

    /**
     * Metal頂点ディスクリプタの設定
     *
     * これはMetalパイプラインに頂点データの解釈方法を教えるための重要な設定です。
     * Nuklearの頂点データとこのディスクリプタの整合性が取れていないとレンダリングが失敗します。
     *
     * 主なポイント:
     * 1. 属性フォーマット
     *    - position: float2 (8バイト)  - オフセット 0
     *    - uv:       float2 (8バイト)  - オフセット 8
     *    - color:    float4 (16バイト) - オフセット 16
     *
     * 2. 頂点データ全体のサイズ
     *    - 合計: 8 floats (32バイト/頂点)
     *
     * 3. バッファインデックス
     *    - すべて同じバッファ(0)から読み取り
     *
     * 注意: この設定はNuklearの頂点レイアウトとシェーダー入力構造体と
     *       完全に整合性が取れている必要があります
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
     *
     * パイプライン設定はGPUでの描画がどのように行われるかを定義します。
     * UIレンダリングに重要な点は下記の通り:
     *
     * 1. シェーダー関数のバインド
     *    - 先ほど定義したバーテックス・フラグメントシェーダーを指定
     *
     * 2. 頂点ディスクリプタ
     *    - 先ほど定義した頂点レイアウトをパイプラインに接続
     *
     * 3. 出力フォーマットとブレンディング
     *    - CAMetalLayerのピクセルフォーマットと一致させる（BGRA8Unorm）
     *    - アルファブレンディングはUI描画に必須（透明度を有効に）
     *    - ブレンドモード: 通常のアルファブレンディング (SrcAlpha, OneMinusSrcAlpha)
     *    - これにより、UIコンポーネントが下の背景と適切に合成される
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
    if (!g_nk_metal.pipelineState) { NSLog(@"Metal pipeline error: %@", error); return NULL; }

    // コマンドバッファ初期化
    nk_buffer_init_default(&g_nk_metal.cmds);

    return &g_ctx;
}

// Metal用 Nuklear 描画
static void nk_metal_render(struct nk_context *ctx, id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable, int width, int height) {
    NSLog(@"[nk_metal_render] called with width=%d, height=%d", width, height);
    
    // パラメータ検証
    if (!ctx) {
        NSLog(@"[nk_metal_render] ERROR: ctx is nil");
        return;
    }
    if (!commandBuffer) {
        NSLog(@"[nk_metal_render] ERROR: commandBuffer is nil");
        return;
    }
    if (!drawable) {
        NSLog(@"[nk_metal_render] ERROR: drawable is nil");
        return;
    }
    if (width <= 0 || height <= 0) {
        NSLog(@"[nk_metal_render] ERROR: Invalid dimensions: %dx%d", width, height);
        return;
    }
    
    // パイプラインステート確認
    if (!g_nk_metal.pipelineState) {
        NSLog(@"[nk_metal_render] ERROR: Pipeline state is nil");
        return;
    }
    MTLRenderPassDescriptor *passDesc = [MTLRenderPassDescriptor renderPassDescriptor];
    passDesc.colorAttachments[0].texture = drawable.texture;
    passDesc.colorAttachments[0].loadAction = MTLLoadActionClear;
    passDesc.colorAttachments[0].storeAction = MTLStoreActionStore;
    passDesc.colorAttachments[0].clearColor = MTLClearColorMake(0.1, 0.18, 0.24, 1.0);

    id<MTLRenderCommandEncoder> encoder = [commandBuffer renderCommandEncoderWithDescriptor:passDesc];
    [encoder setRenderPipelineState:g_nk_metal.pipelineState];
    NSLog(@"[nk_metal_render] encoder and pipeline set");

    // --- NuklearコマンドバッファをMetalバッファに変換・転送・描画 ---
    struct nk_buffer vbuf, ibuf;
    nk_buffer_init_default(&vbuf);
    nk_buffer_init_default(&ibuf);

    /**
     * Nuklear の頂点レイアウト設定
     *
     * 注意点：
     * 1. NK_FORMAT_R32G32B32A32_FLOAT の使用
     *    - 元のコードでは NK_FORMAT_R8G8B8A8 （バイト配列）を使用していた
     *    - これをシェーダー側の float4 とメモリレイアウトを一致させるために変更
     *    - 不一致があるとシェーダーが正しく色情報を解釈できない
     *
     * 2. 正確なバイトオフセット
     *    - 位置: 0 バイト目から
     *    - UV: 8 バイト目から (float2 分ずれる)
     *    - 色: 16 バイト目から (float4 分さらにずれる)
     *
     * 3. 頂点サイズは合計 32 バイト (8 floats)
     *    - Metal側の頂点記述子の stride と完全に一致する必要がある
     *    - Nuklearが生成するバッファがこのレイアウトになる
     */
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
        NSLog(@"[nk_metal_render] ERROR: nk_convert failed with code %d", convert_result);
        nk_buffer_free(&vbuf);
        nk_buffer_free(&ibuf);
        return;
    }
    NSLog(@"[nk_metal_render] nk_convert succeeded, vbuf: %lu bytes, ibuf: %lu bytes",
          (unsigned long)nk_buffer_total(&vbuf),
          (unsigned long)nk_buffer_total(&ibuf));

    void *vertexData = nk_buffer_memory(&vbuf);
    void *indexData = nk_buffer_memory(&ibuf);
    NSUInteger vsize = nk_buffer_total(&vbuf);
    NSUInteger isize = nk_buffer_total(&ibuf);
    memcpy(g_nk_metal.vertexBuffer.contents, vertexData, vsize);
    memcpy(g_nk_metal.indexBuffer.contents, indexData, isize);
    NSLog(@"[nk_metal_render] vertex/index data copied: vsize=%lu, isize=%lu", (unsigned long)vsize, (unsigned long)isize);

    [encoder setVertexBuffer:g_nk_metal.vertexBuffer offset:0 atIndex:0];
    
    /**
     * ビューポートサイズをシェーダーに渡す
     *
     * これは座標変換に重要な要素の一つ:
     * - Nuklearは左上原点のピクセル座標系 (0,0 ~ width,height)
     * - Metalのクリップ空間は (-1,-1 ~ 1,1) の正規化デバイス座標
     *
     * シェーダーではこのビューポートサイズを使って、ピクセル座標から
     * 正規化デバイス座標への変換が行われる。これが無いと描画が画面サイズと
     * 一致せず、表示されないか歪んで表示される。
     */
    float viewportSize[2] = {(float)width, (float)height};
    [encoder setVertexBytes:viewportSize length:sizeof(viewportSize) atIndex:1];

    // --- フォントテクスチャをfragment shaderにバインド ---
    [encoder setFragmentTexture:g_nk_metal.font_tex atIndex:0];

    // --- サンプラーを必ずバインド ---
    static id<MTLSamplerState> sampler = nil;
    if (!sampler) {
        MTLSamplerDescriptor *sampDesc = [[MTLSamplerDescriptor alloc] init];
        sampDesc.minFilter = MTLSamplerMinMagFilterLinear;
        sampDesc.magFilter = MTLSamplerMinMagFilterLinear;
        sampler = [g_nk_metal.device newSamplerStateWithDescriptor:sampDesc];
    }
    [encoder setFragmentSamplerState:sampler atIndex:0];

    /**
     * Nuklearの描画コマンドリストの処理
     *
     * Nuklearのコマンドリストをループし、各描画コマンドをMetalの描画命令に変換します。
     * 各コマンドは通常:
     * - 1つのテクスチャ (フォントまたはUIコンポーネント用)
     * - 描画する頂点インデックスの範囲
     * - クリッピング領域
     * を持っています。
     *
     * この部分でエラーがあると、UI要素が表示されなかったり、誤った表示になります。
     */
    // コマンドリストをループして描画
    uint16_t offset = 0;  // nk_draw_indexの代わりにuint16_tを使用
    int draw_count = 0;
    int total_elements = 0;
    NSLog(@"[nk_metal_render] Starting to iterate through draw commands...");
    nk_draw_foreach(cmd, ctx, &g_nk_metal.cmds) {
        if (!cmd->elem_count) {
            NSLog(@"[nk_metal_render] Skipping empty command (elem_count=0)");
            continue;
        }
        
        total_elements += cmd->elem_count;
        NSLog(@"[nk_metal_render] Command %d: elem_count=%d, texture=%p, clip_rect=(%.1f,%.1f %.1fx%.1f)",
              draw_count, cmd->elem_count, cmd->texture.ptr,
              cmd->clip_rect.x, cmd->clip_rect.y, cmd->clip_rect.w, cmd->clip_rect.h);
              
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
        draw_count++;
    }
    NSLog(@"[nk_metal_render] draw command count: %d, total elements: %d", draw_count, total_elements);

    nk_buffer_free(&vbuf);
    nk_buffer_free(&ibuf);
    // --- ここまで ---

    [encoder endEncoding];
    [commandBuffer presentDrawable:drawable];
    NSLog(@"[nk_metal_render] endEncoding and presentDrawable");
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

// Metal用Rendererクラス（macOS用: NSViewベース）
@interface NKMetalRenderer : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, weak) CAMetalLayer *metalLayer;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, assign) struct nk_context *nk_ctx;
@property (nonatomic, assign) BOOL isRendering;
// イベントキュー関連
@property (nonatomic, strong) NSMutableArray *pendingEvents; // 保留中のイベント
@property (nonatomic, strong) NSLock *eventLock;             // イベントキュー用ロック
@property (nonatomic, assign) BOOL needsRedraw;              // 再描画フラグ
@property (nonatomic, assign) NSPoint mousePos;              // 現在のマウス位置
@property (nonatomic, assign) BOOL leftButtonDown;           // 左ボタン状態
@property (nonatomic, assign) BOOL rightButtonDown;          // 右ボタン状態
// マウス処理メソッド
- (void)mouseDownAtPoint:(NSPoint)point left:(BOOL)isLeft;
- (void)mouseUpAtPoint:(NSPoint)point left:(BOOL)isLeft;
- (void)mouseMovedToPoint:(NSPoint)point;
- (void)mouseDraggedToPoint:(NSPoint)point left:(BOOL)isLeft;
@end

@implementation NKMetalRenderer
- (instancetype)initWithLayer:(CAMetalLayer *)layer {
    if (self = [super init]) {
        _device = MTLCreateSystemDefaultDevice();
        if (!_device) {
            NSLog(@"[NKMetalRenderer initWithLayer] ERROR: Failed to create Metal device");
            return nil;
        }
        
        _commandQueue = [_device newCommandQueue];
        if (!_commandQueue) {
            NSLog(@"[NKMetalRenderer initWithLayer] ERROR: Failed to create command queue");
            return nil;
        }
        
        _metalLayer = layer;
        if (!_metalLayer) {
            NSLog(@"[NKMetalRenderer initWithLayer] ERROR: Metal layer is nil");
            return nil;
        }
        
        _metalLayer.device = _device;
        _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        
        // イベント処理関連の初期化
        _pendingEvents = [NSMutableArray array];
        _eventLock = [[NSLock alloc] init];
        _needsRedraw = YES;
        _leftButtonDown = NO;
        _rightButtonDown = NO;
        _mousePos = NSZeroPoint;
        
        // 描画サイズが0になっていないかチェック
        CGSize drawableSize = _metalLayer.drawableSize;
        if (drawableSize.width <= 0 || drawableSize.height <= 0) {
            NSLog(@"[NKMetalRenderer initWithLayer] WARNING: Invalid drawable size: %.0fx%.0f",
                  drawableSize.width, drawableSize.height);
            // 安全な値を設定
            drawableSize = CGSizeMake(800, 600);
            _metalLayer.drawableSize = drawableSize;
        }
        
        _width = (int)drawableSize.width;
        _height = (int)drawableSize.height;
        NSLog(@"[NKMetalRenderer initWithLayer] Initializing with size: %dx%d", _width, _height);
        
        _nk_ctx = nk_metal_init(_device, _width, _height);
        if (!_nk_ctx) {
            NSLog(@"[NKMetalRenderer initWithLayer] ERROR: Failed to initialize Nuklear Metal");
            return nil;
        }
        
        _isRendering = NO;
        NSLog(@"[NKMetalRenderer initWithLayer] Successfully initialized");
    }
    return self;
}
- (void)resizeDrawable:(CGSize)size {
    CGFloat scale = [[NSScreen mainScreen] backingScaleFactor];
    _metalLayer.drawableSize = CGSizeMake(size.width * scale, size.height * scale);
    _width = (int)(_metalLayer.drawableSize.width);
    _height = (int)(_metalLayer.drawableSize.height);
    NSLog(@"[NKMetalRenderer resizeDrawable] new size: %dx%d, scale: %.2f", _width, _height, scale);
}

// Y座標を反転（Nuklear座標系に合わせる）
- (NSPoint)convertToNuklearCoordinates:(NSPoint)point {
    NSPoint result = point;
    result.y = _height - point.y; // y座標の反転
    return result;
}

// イベントをキューに追加するヘルパーメソッド
- (void)queueEvent:(NSDictionary *)event {
    [_eventLock lock];
    [_pendingEvents addObject:event];
    _needsRedraw = YES;
    [_eventLock unlock];
    
    // メソッド呼び出しがタイムリーになるように即時描画要求
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!self.isRendering) {
            [self render];
        }
    });
}

// マウスボタン押下イベント
- (void)mouseDownAtPoint:(NSPoint)point left:(BOOL)isLeft {
    NSPoint nuklearPoint = [self convertToNuklearCoordinates:point];
    _mousePos = nuklearPoint;
    
    if (isLeft) {
        _leftButtonDown = YES;
    } else {
        _rightButtonDown = YES;
    }
    
    [self queueEvent:@{
        @"type": @"mouseDown",
        @"button": @(isLeft ? NK_BUTTON_LEFT : NK_BUTTON_RIGHT),
        @"position": [NSValue valueWithPoint:nuklearPoint]
    }];
    
    NSLog(@"MouseDown at (%.1f, %.1f), left: %@", nuklearPoint.x, nuklearPoint.y, isLeft ? @"YES" : @"NO");
}

// マウスボタン解放イベント
- (void)mouseUpAtPoint:(NSPoint)point left:(BOOL)isLeft {
    NSPoint nuklearPoint = [self convertToNuklearCoordinates:point];
    _mousePos = nuklearPoint;
    
    if (isLeft) {
        _leftButtonDown = NO;
    } else {
        _rightButtonDown = NO;
    }
    
    [self queueEvent:@{
        @"type": @"mouseUp",
        @"button": @(isLeft ? NK_BUTTON_LEFT : NK_BUTTON_RIGHT),
        @"position": [NSValue valueWithPoint:nuklearPoint]
    }];
    
    NSLog(@"MouseUp at (%.1f, %.1f), left: %@", nuklearPoint.x, nuklearPoint.y, isLeft ? @"YES" : @"NO");
}

// マウス移動イベント
- (void)mouseMovedToPoint:(NSPoint)point {
    NSPoint nuklearPoint = [self convertToNuklearCoordinates:point];
    _mousePos = nuklearPoint;
    
    [self queueEvent:@{
        @"type": @"mouseMove",
        @"position": [NSValue valueWithPoint:nuklearPoint]
    }];
}

// マウスドラッグイベント
- (void)mouseDraggedToPoint:(NSPoint)point left:(BOOL)isLeft {
    NSPoint nuklearPoint = [self convertToNuklearCoordinates:point];
    _mousePos = nuklearPoint;
    
    [self queueEvent:@{
        @"type": @"mouseDrag",
        @"position": [NSValue valueWithPoint:nuklearPoint],
        @"button": @(isLeft ? NK_BUTTON_LEFT : NK_BUTTON_RIGHT)
    }];
    
    // ドラッグログ（頻度を制限）
    static int dragCounter = 0;
    if (dragCounter++ % 30 == 0) {
        NSLog(@"MouseDrag at (%.1f, %.1f), left: %@", nuklearPoint.x, nuklearPoint.y, isLeft ? @"YES" : @"NO");
    }
}
- (void)render {
    if (self.isRendering) {
        NSLog(@"[NKMetalRenderer render] skipped (already rendering)");
        return;
    }
    self.isRendering = YES;
    NSLog(@"[NKMetalRenderer render] called with viewport: %dx%d", _width, _height);
    
    // --- Nuklear UI構築 ---
    nk_input_begin(&g_ctx);
    
    // キューからイベント処理
    [_eventLock lock];
    NSArray *events = [_pendingEvents copy];
    [_pendingEvents removeAllObjects];
    [_eventLock unlock];
    
    // イベント処理ログ
    if (events.count > 0) {
        NSLog(@"[NKMetalRenderer render] Processing %lu events", (unsigned long)events.count);
    }
    
    // キュー内のイベントをNuklearに通知
    for (NSDictionary *event in events) {
        NSString *type = event[@"type"];
        
        if ([type isEqualToString:@"mouseMove"] || [type isEqualToString:@"mouseDrag"]) {
            NSPoint point = [event[@"position"] pointValue];
            nk_input_motion(&g_ctx, (int)point.x, (int)point.y);
            NSLog(@"[NKMetalRenderer render] nk_input_motion(%d, %d)", (int)point.x, (int)point.y);
        }
        else if ([type isEqualToString:@"mouseDown"]) {
            NSPoint point = [event[@"position"] pointValue];
            int button = [event[@"button"] intValue];
            nk_input_button(&g_ctx, button, (int)point.x, (int)point.y, 1);
            NSLog(@"[NKMetalRenderer render] nk_input_button(%d, %d, %d, 1)", button, (int)point.x, (int)point.y);
        }
        else if ([type isEqualToString:@"mouseUp"]) {
            NSPoint point = [event[@"position"] pointValue];
            int button = [event[@"button"] intValue];
            nk_input_button(&g_ctx, button, (int)point.x, (int)point.y, 0);
            NSLog(@"[NKMetalRenderer render] nk_input_button(%d, %d, %d, 0)", button, (int)point.x, (int)point.y);
        }
        else if ([type isEqualToString:@"scroll"]) {
            float deltaX = [event[@"deltaX"] floatValue];
            float deltaY = [event[@"deltaY"] floatValue];
            nk_input_scroll(&g_ctx, nk_vec2(deltaX, deltaY));
        }
    }
    
    nk_input_end(&g_ctx);
    
    // 描画領域の確認
    NSLog(@"[NKMetalRenderer render] Current drawable size: %.0fx%.0f",
          _metalLayer.drawableSize.width, _metalLayer.drawableSize.height);

    // ウィンドウのサイズと位置を描画領域に合わせて調整
    if (nk_begin(&g_ctx, "Demo", nk_rect(50, 50, (float)_width - 100, (float)_height - 100), NK_WINDOW_BORDER|NK_WINDOW_MOVABLE|NK_WINDOW_SCALABLE|NK_WINDOW_MINIMIZABLE|NK_WINDOW_TITLE)) {
        // タイトルと基本コントロール
        nk_layout_row_dynamic(&g_ctx, 30, 1);
        nk_label(&g_ctx, "Hello, Nuklear + Metal!", NK_TEXT_LEFT);
        
        // ボタンを追加（視覚的に確認しやすい）
        nk_layout_row_dynamic(&g_ctx, 30, 2);
        if (nk_button_label(&g_ctx, "Button 1")) {
            NSLog(@"Button 1 pressed!");
        }
        if (nk_button_label(&g_ctx, "Button 2")) {
            NSLog(@"Button 2 pressed!");
        }
        
        // スライダー（より複雑なコントロール）
        static float value = 0.5f;
        nk_layout_row_dynamic(&g_ctx, 30, 1);
        nk_property_float(&g_ctx, "Value:", 0, &value, 1.0f, 0.01f, 0.01f);
        nk_slider_float(&g_ctx, 0, &value, 1.0f, 0.01f);
        
        // 色選択コントロール
        static struct nk_colorf bg = {0.3f, 0.4f, 0.8f, 1.0f};
        nk_layout_row_dynamic(&g_ctx, 120, 1);
        bg = nk_color_picker(&g_ctx, bg, NK_RGB);
        
        NSLog(@"[NKMetalRenderer render] nk_begin/UI controls rendered");
    }
    nk_end(&g_ctx);
    // --- Nuklear UI構築ここまで ---

    // ドローアブルの取得を確実に行う
    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) {
        NSLog(@"[NKMetalRenderer render] ERROR: Failed to get drawable from layer");
        self.isRendering = NO;
        return;
    }
    
    // コンテキスト確認
    if (!_nk_ctx) {
        NSLog(@"[NKMetalRenderer render] ERROR: Nuklear context is NULL");
        self.isRendering = NO;
        return;
    }
    
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    if (!commandBuffer) {
        NSLog(@"[NKMetalRenderer render] ERROR: Failed to create command buffer");
        self.isRendering = NO;
        return;
    }
    
    NSLog(@"[NKMetalRenderer render] commandBuffer created");
    
    // 検証
    NSLog(@"[NKMetalRenderer render] Validation: nk_ctx=%p, commandBuffer=%p, drawable=%p, w=%d, h=%d",
          _nk_ctx, commandBuffer, drawable, _width, _height);
          
    nk_metal_render(_nk_ctx, commandBuffer, drawable, _width, _height);
    [commandBuffer commit];
    NSLog(@"[NKMetalRenderer render] commandBuffer committed");
    self.isRendering = NO;

    // Nuklearのフレーム切り替え（必須）
    nk_clear(&g_ctx);
}
@end

// macOS用Metal NSView
@interface NuklearMetalView : NSView
@property (nonatomic, strong) NKMetalRenderer *renderer;
@property (nonatomic, assign) CVDisplayLinkRef displayLink;
@property (atomic, assign) BOOL renderRequested;
@end

static CVReturn DisplayLinkCallback(CVDisplayLinkRef displayLink,
                                    const CVTimeStamp *now,
                                    const CVTimeStamp *outputTime,
                                    CVOptionFlags flagsIn,
                                    CVOptionFlags *flagsOut,
                                    void *displayLinkContext) {
    NuklearMetalView *view = (__bridge NuklearMetalView *)displayLinkContext;
    // すでに描画要求が積まれていれば新たに積まない
    if (view.renderRequested) return kCVReturnSuccess;
    view.renderRequested = YES;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view.renderer) {
            [view.renderer render];
        }
        view.renderRequested = NO;
    });
    return kCVReturnSuccess;
}

@implementation NuklearMetalView
@synthesize displayLink = _displayLink;

- (BOOL)isOpaque {
    return YES;
}

- (CALayer *)makeBackingLayer {
    return [CAMetalLayer layer];
}

- (instancetype)initWithFrame:(NSRect)frame {
    NSLog(@"NuklearMetalView: initWithFrame called");
    if (self = [super initWithFrame:frame]) {
        self.wantsLayer = YES;
        self.layer = [CAMetalLayer layer];
        NSLog(@"NuklearMetalView: self.layer class = %@", NSStringFromClass([self.layer class]));
        CAMetalLayer *layer = (CAMetalLayer *)self.layer;
        
        // Metalレイヤー設定の最適化
        layer.framebufferOnly = YES;
        layer.opaque = YES;
        layer.drawableSize = frame.size;
        CGFloat scale = [[NSScreen mainScreen] backingScaleFactor];
        layer.contentsScale = scale;
        self.renderer = [[NKMetalRenderer alloc] initWithLayer:layer];
        if (self.renderer) {
            NSLog(@"NuklearMetalView: self.renderer initialized");
        } else {
            NSLog(@"NuklearMetalView: self.renderer is nil after init");
        }
        
        // マウストラッキングに関する設定
        // マウス移動イベントを有効化（これがないとmouseMoved:が呼ばれない）
        [[self window] setAcceptsMouseMovedEvents:YES];
        
        // トラッキングエリアを設定（マウスの入退出を検知するため）
        NSTrackingAreaOptions options = (NSTrackingActiveAlways |
                                          NSTrackingInVisibleRect |
                                          NSTrackingMouseEnteredAndExited |
                                          NSTrackingMouseMoved);
        
        NSTrackingArea *trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                                     options:options
                                                                       owner:self
                                                                    userInfo:nil];
        [self addTrackingArea:trackingArea];
        
        // CVDisplayLinkで定期描画
        CVDisplayLinkRef link;
        CVDisplayLinkCreateWithActiveCGDisplays(&link);
        CVDisplayLinkSetOutputCallback(link, &DisplayLinkCallback, (__bridge void *)self);
        CVDisplayLinkStart(link);
        self.displayLink = link;
    }
    return self;
}
- (void)dealloc {
    if (self.displayLink) {
        CVDisplayLinkStop(self.displayLink);
        CVDisplayLinkRelease(self.displayLink);
        self.displayLink = NULL;
    }
    nk_free(&g_ctx);  // Nuklearのリソースを解放
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self.renderer resizeDrawable:self.bounds.size];
}

// マウスイベントハンドラの追加
- (void)mouseDown:(NSEvent *)event {
    NSPoint locationInWindow = event.locationInWindow;
    NSPoint location = [self convertPoint:locationInWindow fromView:nil];
    if (self.renderer) {
        [self.renderer mouseDownAtPoint:location left:YES];
    }
}

- (void)mouseUp:(NSEvent *)event {
    NSPoint locationInWindow = event.locationInWindow;
    NSPoint location = [self convertPoint:locationInWindow fromView:nil];
    if (self.renderer) {
        [self.renderer mouseUpAtPoint:location left:YES];
    }
}

- (void)rightMouseDown:(NSEvent *)event {
    NSPoint locationInWindow = event.locationInWindow;
    NSPoint location = [self convertPoint:locationInWindow fromView:nil];
    if (self.renderer) {
        [self.renderer mouseDownAtPoint:location left:NO];
    }
}

- (void)rightMouseUp:(NSEvent *)event {
    NSPoint locationInWindow = event.locationInWindow;
    NSPoint location = [self convertPoint:locationInWindow fromView:nil];
    if (self.renderer) {
        [self.renderer mouseUpAtPoint:location left:NO];
    }
}

- (void)mouseMoved:(NSEvent *)event {
    NSPoint locationInWindow = event.locationInWindow;
    NSPoint location = [self convertPoint:locationInWindow fromView:nil];
    if (self.renderer) {
        [self.renderer mouseMovedToPoint:location];
    }
}

- (void)mouseDragged:(NSEvent *)event {
    NSPoint locationInWindow = event.locationInWindow;
    NSPoint location = [self convertPoint:locationInWindow fromView:nil];
    if (self.renderer) {
        [self.renderer mouseDraggedToPoint:location left:YES];
    }
}

- (void)rightMouseDragged:(NSEvent *)event {
    NSPoint locationInWindow = event.locationInWindow;
    NSPoint location = [self convertPoint:locationInWindow fromView:nil];
    if (self.renderer) {
        [self.renderer mouseDraggedToPoint:location left:NO];
    }
}

// マウス入力を受け取るために必要
- (BOOL)acceptsFirstResponder {
    return YES;
}
@end

// アプリ起動用（macOS用）
@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong, nonatomic) NSWindow *window;
@end

@implementation AppDelegate
- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    NSLog(@"AppDelegate: applicationDidFinishLaunching");
    NSRect frame = NSMakeRect(100, 100, 800, 600); // 位置(x,y)とサイズ(width,height)を明示指定
    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable)
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    NuklearMetalView *view = [[NuklearMetalView alloc] initWithFrame:frame];
    [self.window setContentView:view];
    [self.window makeKeyAndOrderFront:nil];
}
@end

/**
 * メイン関数：アプリケーションのエントリポイント
 *
 * このアプリは以下の処理フローで動作します:
 * 1. AppDelegateが作成され、NSApplicationに設定される
 * 2. applicationDidFinishLaunchingでNSWindowとNuklearMetalViewが初期化
 * 3. NuklearMetalViewはCAMetalLayerを持ち、レンダラーを初期化
 * 4. DisplayLinkCallbackで定期的に描画リクエストが発生
 * 5. NKMetalRendererがNuklear UIを構築し、Metal APIを使って描画
 *
 * 主な改善点:
 * - フォントテクスチャのフォーマット: RGBA32 -> ALPHA8 (1/4のメモリサイズ)
 * - 頂点データ形式: R8G8B8A8バイト配列 -> float4 (シェーダーとの整合性)
 * - 座標変換: ピクセル座標からNDC座標への正確な変換とY軸反転
 * - エラー検出: 重要な箇所でのnullチェックとログ出力追加
 */
int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
