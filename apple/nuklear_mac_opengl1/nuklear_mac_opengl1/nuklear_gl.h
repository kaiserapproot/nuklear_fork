#pragma once
/*
 * Nuklear - v1.32.0 - public domain
 * no warrenty implied; use at your own risk.
 * authored from 2015-2017 by Micha Mettke
 */
 /*
  * ==============================================================
  *
  *                              API
  *
  * ===============================================================
  */
#ifndef NK_GL1_H_
#define NK_GL1_H_

// macOS向けにインクルードファイルを変更
#include <OpenGL/gl.h>
#include <OpenGL/glu.h>

enum nk_gl1_init_state
{
    NK_GL1_DEFAULT = 0
};

NK_API struct nk_context* nk_gl1_init(enum nk_gl1_init_state);
NK_API void nk_gl1_font_stash_begin(struct nk_font_atlas** atlas);
NK_API void nk_gl1_font_stash_end(void);

NK_API void nk_gl1_new_frame(void);
NK_API void nk_gl1_render(enum nk_anti_aliasing);
NK_API void nk_gl1_shutdown(void);

// macOS向けイベント処理関数
NK_API void nk_gl1_resize(int width, int height);

// macOS向けマウス入力処理
NK_API void nk_gl1_mouse_button_callback(int button, int action, int mods);
NK_API void nk_gl1_mouse_position_callback(double x, double y);
NK_API void nk_gl1_scroll_callback(double x, double y);

// macOS向けキー入力処理
NK_API void nk_gl1_char_callback(unsigned int codepoint);
NK_API void nk_gl1_key_callback(int key, int action, int mods);

#endif

/*
 * ==============================================================
 *
 *                          IMPLEMENTATION
 *
 * ===============================================================
 */
#ifdef NK_GL1_IMPLEMENTATION

// macOS API用インクルード
#include <ApplicationServices/ApplicationServices.h>

#ifndef NK_GL1_TEXT_MAX
#define NK_GL1_TEXT_MAX 256
#endif
#ifndef NK_GL1_DOUBLE_CLICK_LO
#define NK_GL1_DOUBLE_CLICK_LO 0.02
#endif
#ifndef NK_GL1_DOUBLE_CLICK_HI
#define NK_GL1_DOUBLE_CLICK_HI 0.2
#endif

// macOS向けキー定義
#define NK_KEY_ESCAPE        53
#define NK_KEY_RETURN        36
#define NK_KEY_TAB           48
#define NK_KEY_BACKSPACE     51
#define NK_KEY_UP            126
#define NK_KEY_DOWN          125
#define NK_KEY_LEFT          123
#define NK_KEY_RIGHT         124
#define NK_KEY_HOME          115
#define NK_KEY_END           119
#define NK_KEY_DELETE        117
#define NK_KEY_SPACE         49
#define NK_KEY_SHIFT         56
#define NK_KEY_CONTROL       59
#define NK_KEY_PAGE_UP       116
#define NK_KEY_PAGE_DOWN     121

struct nk_gl1_device
{
    struct nk_buffer cmds;
    struct nk_draw_null_texture null;
    GLuint font_tex;
};

struct nk_gl1_vertex
{
    float position[2];
    float uv[2];
    nk_byte col[4];
};

static struct nk_gl1
{
    int width, height;
    int display_width, display_height;
    struct nk_gl1_device ogl;
    struct nk_context ctx;
    struct nk_font_atlas atlas;
    struct nk_vec2 fb_scale;
    unsigned int text[NK_GL1_TEXT_MAX];
    int text_len;
    struct nk_vec2 scroll;
    double last_button_click;
    int is_double_click_down;
    struct nk_vec2 double_click_pos;
    int is_left_down;
    int is_middle_down;
    int is_right_down;
} gl1;

NK_INTERN void
nk_gl1_device_upload_atlas(const void* image, int width, int height)
{
    struct nk_gl1_device* dev = &gl1.ogl;
    glGenTextures(1, &dev->font_tex);
    glBindTexture(GL_TEXTURE_2D, dev->font_tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)width, (GLsizei)height, 0,
        GL_RGBA, GL_UNSIGNED_BYTE, image);
}

NK_API void
nk_gl1_render(enum nk_anti_aliasing AA)
{
    /* setup global state */
    struct nk_gl1_device* dev = &gl1.ogl;
    glPushAttrib(GL_ENABLE_BIT | GL_COLOR_BUFFER_BIT | GL_TRANSFORM_BIT);
    glDisable(GL_CULL_FACE);
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_SCISSOR_TEST);
    glEnable(GL_BLEND);
    glEnable(GL_TEXTURE_2D);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    /* setup viewport/project */
    glViewport(0, 0, (GLsizei)gl1.display_width, (GLsizei)gl1.display_height);
    glMatrixMode(GL_PROJECTION);
    glPushMatrix();
    glLoadIdentity();
    glOrtho(0.0f, gl1.width, gl1.height, 0.0f, -1.0f, 1.0f);
    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    glLoadIdentity();

    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glEnableClientState(GL_COLOR_ARRAY);
    {
        GLsizei vs = sizeof(struct nk_gl1_vertex);
        size_t vp = offsetof(struct nk_gl1_vertex, position);
        size_t vt = offsetof(struct nk_gl1_vertex, uv);
        size_t vc = offsetof(struct nk_gl1_vertex, col);

        /* convert from command queue into draw list and draw to screen */
        const struct nk_draw_command* cmd;
        const nk_draw_index* offset = NULL;
        struct nk_buffer vbuf, ebuf;

        /* fill convert configuration */
        struct nk_convert_config config;
        static const struct nk_draw_vertex_layout_element vertex_layout[] = {
            {NK_VERTEX_POSITION, NK_FORMAT_FLOAT, NK_OFFSETOF(struct nk_gl1_vertex, position)},
            {NK_VERTEX_TEXCOORD, NK_FORMAT_FLOAT, NK_OFFSETOF(struct nk_gl1_vertex, uv)},
            {NK_VERTEX_COLOR, NK_FORMAT_R8G8B8A8, NK_OFFSETOF(struct nk_gl1_vertex, col)},
            {NK_VERTEX_LAYOUT_END}
        };
        NK_MEMSET(&config, 0, sizeof(config));
        config.vertex_layout = vertex_layout;
        config.vertex_size = sizeof(struct nk_gl1_vertex);
        config.vertex_alignment = NK_ALIGNOF(struct nk_gl1_vertex);
        config.null = dev->null;
        config.circle_segment_count = 22;
        config.curve_segment_count = 22;
        config.arc_segment_count = 22;
        config.global_alpha = 1.0f;
        config.shape_AA = AA;
        config.line_AA = AA;

        /* convert shapes into vertexes */
        nk_buffer_init_default(&vbuf);
        nk_buffer_init_default(&ebuf);
        nk_convert(&gl1.ctx, &dev->cmds, &vbuf, &ebuf, &config);

        /* setup vertex buffer pointer */
        {
            const void* vertices = nk_buffer_memory_const(&vbuf);
            glVertexPointer(2, GL_FLOAT, vs, (const void*)((const nk_byte*)vertices + vp));
            glTexCoordPointer(2, GL_FLOAT, vs, (const void*)((const nk_byte*)vertices + vt));
            glColorPointer(4, GL_UNSIGNED_BYTE, vs, (const void*)((const nk_byte*)vertices + vc));
        }

        /* iterate over and execute each draw command */
        offset = (const nk_draw_index*)nk_buffer_memory_const(&ebuf);
        nk_draw_foreach(cmd, &gl1.ctx, &dev->cmds)
        {
            if (!cmd->elem_count) continue;
            glBindTexture(GL_TEXTURE_2D, (GLuint)cmd->texture.id);
            glScissor(
                (GLint)(cmd->clip_rect.x * gl1.fb_scale.x),
                (GLint)((gl1.height - (GLint)(cmd->clip_rect.y + cmd->clip_rect.h)) * gl1.fb_scale.y),
                (GLint)(cmd->clip_rect.w * gl1.fb_scale.x),
                (GLint)(cmd->clip_rect.h * gl1.fb_scale.y));
            glDrawElements(GL_TRIANGLES, (GLsizei)cmd->elem_count, GL_UNSIGNED_SHORT, offset);
            offset += cmd->elem_count;
        }
        nk_clear(&gl1.ctx);
        nk_buffer_free(&vbuf);
        nk_buffer_free(&ebuf);
    }

    /* default OpenGL state */
    glDisableClientState(GL_VERTEX_ARRAY);
    glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    glDisableClientState(GL_COLOR_ARRAY);

    glDisable(GL_CULL_FACE);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_SCISSOR_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_TEXTURE_2D);

    glBindTexture(GL_TEXTURE_2D, 0);
    glMatrixMode(GL_MODELVIEW);
    glPopMatrix();
    glMatrixMode(GL_PROJECTION);
    glPopMatrix();
    glPopAttrib();
}

// macOS用クリップボードハンドリング
NK_INTERN void
nk_gl1_clipboard_paste(nk_handle usr, struct nk_text_edit *edit)
{
    PasteboardRef pasteboard;
    OSStatus status = PasteboardCreate(kPasteboardClipboard, &pasteboard);
    if (status != noErr) return;
    
    PasteboardSynchronize(pasteboard);
    
    ItemCount itemCount;
    status = PasteboardGetItemCount(pasteboard, &itemCount);
    if (status != noErr || itemCount == 0) {
        CFRelease(pasteboard);
        return;
    }
    
    PasteboardItemID itemID;
    status = PasteboardGetItemIdentifier(pasteboard, 1, &itemID);
    if (status != noErr) {
        CFRelease(pasteboard);
        return;
    }
    
    CFArrayRef flavors;
    status = PasteboardCopyItemFlavors(pasteboard, itemID, &flavors);
    if (status != noErr) {
        CFRelease(pasteboard);
        return;
    }
    
    CFIndex flavorCount = CFArrayGetCount(flavors);
    for (CFIndex i = 0; i < flavorCount; i++) {
        CFStringRef flavor = (CFStringRef)CFArrayGetValueAtIndex(flavors, i);
        if (UTTypeConformsTo(flavor, kUTTypeUTF8PlainText) ||
            UTTypeConformsTo(flavor, kUTTypeUTF16PlainText) ||
            UTTypeConformsTo(flavor, kUTTypePlainText)) {
            
            CFDataRef data;
            status = PasteboardCopyItemFlavorData(pasteboard, itemID, flavor, &data);
            if (status == noErr) {
                CFIndex length = CFDataGetLength(data);
                const char *bytes = (const char*)CFDataGetBytePtr(data);
                
                CFStringRef string = CFStringCreateWithBytes(NULL,
                                                           (const UInt8*)bytes,
                                                           length,
                                                           kCFStringEncodingUTF8,
                                                           false);
                if (string) {
                    const char *utf8String = CFStringGetCStringPtr(string, kCFStringEncodingUTF8);
                    if (!utf8String) {
                        CFIndex maxLength = CFStringGetMaximumSizeForEncoding(CFStringGetLength(string), kCFStringEncodingUTF8) + 1;
                        char *buffer = (char*)malloc(maxLength);
                        if (buffer && CFStringGetCString(string, buffer, maxLength, kCFStringEncodingUTF8)) {
                            nk_textedit_paste(edit, buffer, strlen(buffer));
                            free(buffer);
                        }
                    } else {
                        nk_textedit_paste(edit, utf8String, strlen(utf8String));
                    }
                    CFRelease(string);
                }
                
                CFRelease(data);
                break;
            }
        }
    }
    
    CFRelease(flavors);
    CFRelease(pasteboard);
}

NK_INTERN void
nk_gl1_clipboard_copy(nk_handle usr, const char *text, int len)
{
    PasteboardRef pasteboard;
    OSStatus status = PasteboardCreate(kPasteboardClipboard, &pasteboard);
    if (status != noErr) return;
    
    PasteboardClear(pasteboard);
    PasteboardSynchronize(pasteboard);
    
    CFDataRef data = CFDataCreate(kCFAllocatorDefault, (const UInt8*)text, len);
    if (data) {
        PasteboardPutItemFlavor(pasteboard, (PasteboardItemID)1, kUTTypeUTF8PlainText, data, 0);
        CFRelease(data);
    }
    
    CFRelease(pasteboard);
}

NK_API struct nk_context*
nk_gl1_init(enum nk_gl1_init_state init_state)
{
    (void)init_state;
    nk_init_default(&gl1.ctx, 0);
    // クリップボード関数の設定
    gl1.ctx.clip.copy = nk_gl1_clipboard_copy;
    gl1.ctx.clip.paste = nk_gl1_clipboard_paste;
    gl1.ctx.clip.userdata = nk_handle_ptr(0);
    nk_buffer_init_default(&gl1.ogl.cmds);

    gl1.last_button_click = 0;
    gl1.is_double_click_down = nk_false;
    gl1.double_click_pos = nk_vec2(0, 0);
    gl1.is_left_down = nk_false;
    gl1.is_middle_down = nk_false;
    gl1.is_right_down = nk_false;
    gl1.scroll = nk_vec2(0, 0);

    return &gl1.ctx;
}

NK_API void
nk_gl1_font_stash_begin(struct nk_font_atlas** atlas)
{
    nk_font_atlas_init_default(&gl1.atlas);
    nk_font_atlas_begin(&gl1.atlas);
    *atlas = &gl1.atlas;
}

NK_API void
nk_gl1_font_stash_end(void)
{
    const void* image; int w, h;
    image = nk_font_atlas_bake(&gl1.atlas, &w, &h, NK_FONT_ATLAS_RGBA32);
    nk_gl1_device_upload_atlas(image, w, h);
    nk_font_atlas_end(&gl1.atlas, nk_handle_id((int)gl1.ogl.font_tex), &gl1.ogl.null);
    if (gl1.atlas.default_font)
        nk_style_set_font(&gl1.ctx, &gl1.atlas.default_font->handle);
}

NK_API void
nk_gl1_new_frame(void)
{
    nk_input_begin(&gl1.ctx);
    
    // スクロール値を反映
    if (gl1.scroll.x != 0.0f || gl1.scroll.y != 0.0f) {
        nk_input_scroll(&gl1.ctx, gl1.scroll);
        gl1.scroll = nk_vec2(0, 0);
    }
    
    nk_input_end(&gl1.ctx);
}

// サイズ変更時の処理
NK_API void
nk_gl1_resize(int width, int height)
{
    gl1.width = width;
    gl1.height = height;
    gl1.display_width = width;
    gl1.display_height = height;
    gl1.fb_scale.x = 1.0f;
    gl1.fb_scale.y = 1.0f;
}

// マウスボタン処理
NK_API void
nk_gl1_mouse_button_callback(int button, int action, int mods)
{
    double time = CFAbsoluteTimeGetCurrent(); // macOS用の時間取得関数
    (void)mods;
    
    if (button == 0) { // 左ボタン
        if (action == 1) { // 押下
            gl1.is_left_down = nk_true;
            double dt = time - gl1.last_button_click;
            if (dt > NK_GL1_DOUBLE_CLICK_LO && dt < NK_GL1_DOUBLE_CLICK_HI) {
                gl1.is_double_click_down = nk_true;
            }
            gl1.last_button_click = time;
        } else {
            gl1.is_left_down = nk_false;
            gl1.is_double_click_down = nk_false;
        }
    } else if (button == 1) { // 右ボタン
        gl1.is_right_down = action == 1;
    } else if (button == 2) { // 中ボタン
        gl1.is_middle_down = action == 1;
    }
}

// マウス位置処理
NK_API void
nk_gl1_mouse_position_callback(double x, double y)
{
    // マウス位置を更新
    if (gl1.is_left_down) {
        nk_input_button(&gl1.ctx, NK_BUTTON_LEFT, (int)x, (int)y, 1);
    } else {
        nk_input_button(&gl1.ctx, NK_BUTTON_LEFT, (int)x, (int)y, 0);
    }
    
    if (gl1.is_right_down) {
        nk_input_button(&gl1.ctx, NK_BUTTON_RIGHT, (int)x, (int)y, 1);
    } else {
        nk_input_button(&gl1.ctx, NK_BUTTON_RIGHT, (int)x, (int)y, 0);
    }
    
    if (gl1.is_middle_down) {
        nk_input_button(&gl1.ctx, NK_BUTTON_MIDDLE, (int)x, (int)y, 1);
    } else {
        nk_input_button(&gl1.ctx, NK_BUTTON_MIDDLE, (int)x, (int)y, 0);
    }
    
    if (gl1.is_double_click_down) {
        nk_input_button(&gl1.ctx, NK_BUTTON_DOUBLE, (int)x, (int)y, 1);
    } else {
        nk_input_button(&gl1.ctx, NK_BUTTON_DOUBLE, (int)x, (int)y, 0);
    }
    
    nk_input_motion(&gl1.ctx, (int)x, (int)y);
}

// スクロール処理
NK_API void
nk_gl1_scroll_callback(double x, double y)
{
    gl1.scroll.x += (float)x;
    gl1.scroll.y += (float)y;
}

// 文字入力処理
NK_API void
nk_gl1_char_callback(unsigned int codepoint)
{
    if (codepoint > 0 && codepoint < 0x10000) {
        nk_input_unicode(&gl1.ctx, (nk_rune)codepoint);
    }
}

// キー入力処理
NK_API void
nk_gl1_key_callback(int key, int action, int mods)
{
    int down = action == 1;
    
    switch (key) {
        case NK_KEY_DELETE:
            nk_input_key(&gl1.ctx, NK_KEY_DEL, down);
            break;
        case NK_KEY_RETURN:
            nk_input_key(&gl1.ctx, NK_KEY_ENTER, down);
            break;
        case NK_KEY_TAB:
            nk_input_key(&gl1.ctx, NK_KEY_TAB, down);
            break;
        case NK_KEY_BACKSPACE:
            nk_input_key(&gl1.ctx, NK_KEY_BACKSPACE, down);
            break;
        case NK_KEY_UP:
            nk_input_key(&gl1.ctx, NK_KEY_UP, down);
            break;
        case NK_KEY_DOWN:
            nk_input_key(&gl1.ctx, NK_KEY_DOWN, down);
            break;
        case NK_KEY_LEFT:
            if (mods & 256) { // Command/Control
                nk_input_key(&gl1.ctx, NK_KEY_TEXT_WORD_LEFT, down);
            } else {
                nk_input_key(&gl1.ctx, NK_KEY_LEFT, down);
            }
            break;
        case NK_KEY_RIGHT:
            if (mods & 256) { // Command/Control
                nk_input_key(&gl1.ctx, NK_KEY_TEXT_WORD_RIGHT, down);
            } else {
                nk_input_key(&gl1.ctx, NK_KEY_RIGHT, down);
            }
            break;
        case NK_KEY_HOME:
            nk_input_key(&gl1.ctx, NK_KEY_TEXT_START, down);
            nk_input_key(&gl1.ctx, NK_KEY_SCROLL_START, down);
            break;
        case NK_KEY_END:
            nk_input_key(&gl1.ctx, NK_KEY_TEXT_END, down);
            nk_input_key(&gl1.ctx, NK_KEY_SCROLL_END, down);
            break;
        case NK_KEY_PAGE_UP:
            nk_input_key(&gl1.ctx, NK_KEY_SCROLL_UP, down);
            break;
        case NK_KEY_PAGE_DOWN:
            nk_input_key(&gl1.ctx, NK_KEY_SCROLL_DOWN, down);
            break;
        case NK_KEY_SHIFT:
            nk_input_key(&gl1.ctx, NK_KEY_SHIFT, down);
            break;
    }
    
    if (mods & 256) { // Command/Control
        switch (key) {
            case 7: // 'x'
                nk_input_key(&gl1.ctx, NK_KEY_CUT, down);
                break;
            case 8: // 'c'
                nk_input_key(&gl1.ctx, NK_KEY_COPY, down);
                break;
            case 9: // 'v'
                nk_input_key(&gl1.ctx, NK_KEY_PASTE, down);
                break;
            case 0: // 'a'
                nk_input_key(&gl1.ctx, NK_KEY_TEXT_SELECT_ALL, down);
                break;
            case 26: // 'z'
                nk_input_key(&gl1.ctx, NK_KEY_TEXT_UNDO, down);
                break;
            case 25: // 'y'
                nk_input_key(&gl1.ctx, NK_KEY_TEXT_REDO, down);
                break;
        }
    }
}

NK_API void
nk_gl1_shutdown(void)
{
    struct nk_gl1_device* dev = &gl1.ogl;
    nk_font_atlas_clear(&gl1.atlas);
    nk_free(&gl1.ctx);
    glDeleteTextures(1, &dev->font_tex);
    nk_buffer_free(&dev->cmds);
    memset(&gl1, 0, sizeof(gl1));
}

#endif
