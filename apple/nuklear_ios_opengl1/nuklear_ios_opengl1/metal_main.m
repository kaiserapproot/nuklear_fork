#import <AppKit/AppKit.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#define NK_IMPLEMENTATION
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_FONT
#import "nuklear.h"

// Metal用 Nuklear バインディング構造体
typedef struct nk_metal {
    id<MTLDevice> device;
    id<MTLCommandQueue> commandQueue;
    id<MTLLibrary> library;
    id<MTLRenderPipelineState> pipelineState;
    id<MTLBuffer> vertexBuffer;
    id<MTLBuffer> indexBuffer;
    NSUInteger maxVertices;
    NSUInteger maxIndices;
    struct nk_buffer cmds; // Nuklearコマンドバッファ
} nk_metal;
static nk_metal g_nk_metal = {0};

// Nuklear用コンテキスト
static struct nk_context g_ctx;

// Metal用 Nuklear 初期化
static struct nk_context *nk_metal_init(id<MTLDevice> device, int width, int height) {
    (void)device; (void)width; (void)height;
    nk_init_default(&g_ctx, 0);

    g_nk_metal.device = device;
    g_nk_metal.commandQueue = [device newCommandQueue];
    g_nk_metal.maxVertices = 4096;
    g_nk_metal.maxIndices = 8192;
    g_nk_metal.vertexBuffer = [device newBufferWithLength:g_nk_metal.maxVertices * sizeof(float) * 8 options:MTLResourceStorageModeShared];
    g_nk_metal.indexBuffer = [device newBufferWithLength:g_nk_metal.maxIndices * sizeof(uint16_t) options:MTLResourceStorageModeShared];

    // シェーダライブラリ作成
    NSError *error = nil;
    NSString *shaderSrc =
    @"using namespace metal;\n"
    "struct VertexIn { float2 pos [[attribute(0)]], uv [[attribute(1)]]; float4 color [[attribute(2)]]; };\n"
    "struct VertexOut { float4 pos [[position]]; float2 uv; float4 color; };\n"
    "vertex VertexOut v_main(VertexIn in [[stage_in]]) {\n"
    "  VertexOut out; out.pos = float4(in.pos, 0, 1); out.uv = in.uv; out.color = in.color; return out; }\n"
    "fragment float4 f_main(VertexOut in [[stage_in]]) { return in.color; }";
    g_nk_metal.library = [device newLibraryWithSource:shaderSrc options:nil error:&error];
    if (!g_nk_metal.library) { NSLog(@"Metal shader compile error: %@", error); return NULL; }

    // 頂点ディスクリプタを追加
    MTLVertexDescriptor *vertexDescriptor = [[MTLVertexDescriptor alloc] init];
    vertexDescriptor.attributes[0].format = MTLVertexFormatFloat2; // pos
    vertexDescriptor.attributes[0].offset = 0;
    vertexDescriptor.attributes[0].bufferIndex = 0;
    vertexDescriptor.attributes[1].format = MTLVertexFormatFloat2; // uv
    vertexDescriptor.attributes[1].offset = sizeof(float) * 2;
    vertexDescriptor.attributes[1].bufferIndex = 0;
    vertexDescriptor.attributes[2].format = MTLVertexFormatFloat4; // color
    vertexDescriptor.attributes[2].offset = sizeof(float) * 4;
    vertexDescriptor.attributes[2].bufferIndex = 0;
    vertexDescriptor.layouts[0].stride = sizeof(float) * 8;
    vertexDescriptor.layouts[0].stepFunction = MTLVertexStepFunctionPerVertex;

    // パイプライン作成
    MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
    desc.vertexFunction = [g_nk_metal.library newFunctionWithName:@"v_main"];
    desc.fragmentFunction = [g_nk_metal.library newFunctionWithName:@"f_main"];
    desc.vertexDescriptor = vertexDescriptor;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    desc.colorAttachments[0].blendingEnabled = YES;
    desc.colorAttachments[0].rgbBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].alphaBlendOperation = MTLBlendOperationAdd;
    desc.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
    desc.colorAttachments[0].destinationRGBBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha;
    g_nk_metal.pipelineState = [device newRenderPipelineStateWithDescriptor:desc error:&error];
    if (!g_nk_metal.pipelineState) { NSLog(@"Metal pipeline error: %@", error); return NULL; }

    return &g_ctx;
}

// Metal用 Nuklear 描画
static void nk_metal_render(struct nk_context *ctx, id<MTLCommandBuffer> commandBuffer, id<CAMetalDrawable> drawable, int width, int height) {
    NSLog(@"[nk_metal_render] called");
    if (!ctx || !commandBuffer || !drawable) {
        NSLog(@"[nk_metal_render] ctx/commandBuffer/drawable is nil");
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

    // 頂点レイアウト
    static const struct nk_draw_vertex_layout_element vertex_layout[] = {
        {NK_VERTEX_POSITION, NK_FORMAT_FLOAT, 0},
        {NK_VERTEX_TEXCOORD, NK_FORMAT_FLOAT, 8},
        {NK_VERTEX_COLOR, NK_FORMAT_R8G8B8A8, 16},
        {NK_VERTEX_LAYOUT_END}
    };
    struct nk_convert_config config = {0};
    config.vertex_layout = vertex_layout;
    config.vertex_size = sizeof(float)*2 + sizeof(float)*2 + sizeof(nk_byte)*4; // 8*float
    config.vertex_alignment = 4;
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
    NSLog(@"[nk_metal_render] nk_convert result: %d, vbuf: %lu, ibuf: %lu", convert_result, (unsigned long)nk_buffer_total(&vbuf), (unsigned long)nk_buffer_total(&ibuf));

    void *vertexData = nk_buffer_memory(&vbuf);
    void *indexData = nk_buffer_memory(&ibuf);
    NSUInteger vsize = nk_buffer_total(&vbuf);
    NSUInteger isize = nk_buffer_total(&ibuf);
    memcpy(g_nk_metal.vertexBuffer.contents, vertexData, vsize);
    memcpy(g_nk_metal.indexBuffer.contents, indexData, isize);
    NSLog(@"[nk_metal_render] vertex/index data copied: vsize=%lu, isize=%lu", (unsigned long)vsize, (unsigned long)isize);

    [encoder setVertexBuffer:g_nk_metal.vertexBuffer offset:0 atIndex:0];

    // コマンドリストをループして描画（テクスチャ未対応の最小例）
    const nk_draw_index *offset = 0;
    int draw_count = 0;
    nk_draw_foreach(cmd, ctx, &g_nk_metal.cmds) {
        if (!cmd->elem_count) continue;
        [encoder drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:cmd->elem_count
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:g_nk_metal.indexBuffer
                     indexBufferOffset:(const char*)offset - (const char*)nk_buffer_memory(&ibuf)];
        offset += cmd->elem_count;
        draw_count++;
    }
    NSLog(@"[nk_metal_render] draw command count: %d", draw_count);

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
}

// Metal用Rendererクラス（macOS用: NSViewベース）
@interface NKMetalRenderer : NSObject
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, weak) CAMetalLayer *metalLayer;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, assign) struct nk_context *nk_ctx;
- (instancetype)initWithLayer:(CAMetalLayer *)layer;
- (void)resizeDrawable:(CGSize)size;
- (void)render;
@end

@implementation NKMetalRenderer
- (instancetype)initWithLayer:(CAMetalLayer *)layer {
    if (self = [super init]) {
        _device = MTLCreateSystemDefaultDevice();
        _commandQueue = [_device newCommandQueue];
        _metalLayer = layer;
        _metalLayer.device = _device;
        _metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
        _width = (int)_metalLayer.drawableSize.width;
        _height = (int)_metalLayer.drawableSize.height;
        _nk_ctx = nk_metal_init(_device, _width, _height);
    }
    return self;
}
- (void)resizeDrawable:(CGSize)size {
    _metalLayer.drawableSize = size;
    _width = (int)size.width;
    _height = (int)size.height;
}
- (void)render {
    NSLog(@"[NKMetalRenderer render] called");
    // --- Nuklear UI構築 ---
    nk_input_begin(&g_ctx);
    // 必要ならここで入力処理を追加
    nk_input_end(&g_ctx);

    if (nk_begin(&g_ctx, "Demo", nk_rect(50, 50, 230, 150), NK_WINDOW_BORDER|NK_WINDOW_MOVABLE|NK_WINDOW_SCALABLE|NK_WINDOW_MINIMIZABLE|NK_WINDOW_TITLE)) {
        nk_layout_row_dynamic(&g_ctx, 30, 1);
        nk_label(&g_ctx, "Hello, Nuklear + Metal!", NK_TEXT_LEFT);
        NSLog(@"[NKMetalRenderer render] nk_begin/nk_label called");
    }
    nk_end(&g_ctx);
    // --- Nuklear UI構築ここまで ---

    id<CAMetalDrawable> drawable = [_metalLayer nextDrawable];
    if (!drawable) {
        NSLog(@"[NKMetalRenderer render] drawable is nil");
        return;
    }
    id<MTLCommandBuffer> commandBuffer = [_commandQueue commandBuffer];
    NSLog(@"[NKMetalRenderer render] commandBuffer created");
    nk_metal_render(_nk_ctx, commandBuffer, drawable, _width, _height);
    [commandBuffer commit];
    NSLog(@"[NKMetalRenderer render] commandBuffer committed");
}
@end

// macOS用Metal NSView
@interface NuklearMetalView : NSView
@property (nonatomic, strong) NKMetalRenderer *renderer;
@property (nonatomic, assign) CVDisplayLinkRef displayLink;
@end

static CVReturn DisplayLinkCallback(CVDisplayLinkRef displayLink,
                                    const CVTimeStamp *now,
                                    const CVTimeStamp *outputTime,
                                    CVOptionFlags flagsIn,
                                    CVOptionFlags *flagsOut,
                                    void *displayLinkContext) {
    NSLog(@"DisplayLinkCallback called");
    @autoreleasepool {
        NuklearMetalView *view = (__bridge NuklearMetalView *)displayLinkContext;
        dispatch_async(dispatch_get_main_queue(), ^{
            [view display];
        });
    }
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
        self.renderer = [[NKMetalRenderer alloc] initWithLayer:layer];
        if (self.renderer) {
            NSLog(@"NuklearMetalView: self.renderer initialized");
        } else {
            NSLog(@"NuklearMetalView: self.renderer is nil after init");
        }
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
}
- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self.renderer resizeDrawable:self.bounds.size];
}
- (void)drawRect:(NSRect)dirtyRect {
    NSLog(@"drawRect called");
    if (!self.renderer) {
        NSLog(@"self.renderer is nil!");
        return;
    }
    [super drawRect:dirtyRect];
    [self.renderer render];
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

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app run];
    }
    return 0;
}
