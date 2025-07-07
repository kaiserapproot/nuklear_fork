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
#ifndef NK_GL2_H_
#define NK_GL2_H_

#include <GL/gl.h>
#include <GL/glu.h>
#ifndef GET_X_LPARAM
#define GET_X_LPARAM(lp) ((int)(short)LOWORD(lp))
#endif
#ifndef GET_Y_LPARAM
#define GET_Y_LPARAM(lp) ((int)(short)HIWORD(lp))
#endif
enum nk_gl2_init_state
{
    NK_GL2_DEFAULT = 0
};

NK_API struct nk_context* nk_gl2_init(enum nk_gl2_init_state);
NK_API void nk_gl2_font_stash_begin(struct nk_font_atlas** atlas);
NK_API void nk_gl2_font_stash_end(void);

NK_API void nk_gl2_new_frame(void);
NK_API void nk_gl2_render(enum nk_anti_aliasing);
NK_API void nk_gl2_shutdown(void);

#endif

/*
 * ==============================================================
 *
 *                          IMPLEMENTATION
 *
 * ===============================================================
 */
#ifdef NK_GL2_IMPLEMENTATION

#ifndef NK_GL2_TEXT_MAX
#define NK_GL2_TEXT_MAX 256
#endif
#ifndef NK_GL2_DOUBLE_CLICK_LO
#define NK_GL2_DOUBLE_CLICK_LO 0.02
#endif
#ifndef NK_GL2_DOUBLE_CLICK_HI
#define NK_GL2_DOUBLE_CLICK_HI 0.2
#endif

struct nk_gl2_device
{
    struct nk_buffer cmds;
    struct nk_draw_null_texture null;
    GLuint font_tex;
};

struct nk_gl2_vertex
{
    float position[2];
    float uv[2];
    nk_byte col[4];
};

static struct nk_gl2
{
    int width, height;
    int display_width, display_height;
    struct nk_gl2_device ogl;
    struct nk_context ctx;
    struct nk_font_atlas atlas;
    struct nk_vec2 fb_scale;
    unsigned int text[NK_GL2_TEXT_MAX];
    int text_len;
    struct nk_vec2 scroll;
    double last_button_click;
    int is_double_click_down;
    struct nk_vec2 double_click_pos;
} gl2;

NK_INTERN void
nk_gl2_device_upload_atlas(const void* image, int width, int height)
{
    struct nk_gl2_device* dev = &gl2.ogl;
    glGenTextures(1, &dev->font_tex);
    glBindTexture(GL_TEXTURE_2D, dev->font_tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)width, (GLsizei)height, 0,
        GL_RGBA, GL_UNSIGNED_BYTE, image);
}

NK_API void
nk_gl2_render(enum nk_anti_aliasing AA)
{
    /* setup global state */
    struct nk_gl2_device* dev = &gl2.ogl;
    glPushAttrib(GL_ENABLE_BIT | GL_COLOR_BUFFER_BIT | GL_TRANSFORM_BIT);
    glDisable(GL_CULL_FACE);
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_SCISSOR_TEST);
    glEnable(GL_BLEND);
    glEnable(GL_TEXTURE_2D);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    /* setup viewport/project */
    glViewport(0, 0, (GLsizei)gl2.display_width, (GLsizei)gl2.display_height);
    glMatrixMode(GL_PROJECTION);
    glPushMatrix();
    glLoadIdentity();
    glOrtho(0.0f, gl2.width, gl2.height, 0.0f, -1.0f, 1.0f);
    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    glLoadIdentity();

    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glEnableClientState(GL_COLOR_ARRAY);
    {
        GLsizei vs = sizeof(struct nk_gl2_vertex);
        size_t vp = offsetof(struct nk_gl2_vertex, position);
        size_t vt = offsetof(struct nk_gl2_vertex, uv);
        size_t vc = offsetof(struct nk_gl2_vertex, col);

        /* convert from command queue into draw list and draw to screen */
        const struct nk_draw_command* cmd;
        const nk_draw_index* offset = NULL;
        struct nk_buffer vbuf, ebuf;

        /* fill convert configuration */
        struct nk_convert_config config;
        static const struct nk_draw_vertex_layout_element vertex_layout[] = {
            {NK_VERTEX_POSITION, NK_FORMAT_FLOAT, NK_OFFSETOF(struct nk_gl2_vertex, position)},
            {NK_VERTEX_TEXCOORD, NK_FORMAT_FLOAT, NK_OFFSETOF(struct nk_gl2_vertex, uv)},
            {NK_VERTEX_COLOR, NK_FORMAT_R8G8B8A8, NK_OFFSETOF(struct nk_gl2_vertex, col)},
            {NK_VERTEX_LAYOUT_END}
        };
        NK_MEMSET(&config, 0, sizeof(config));
        config.vertex_layout = vertex_layout;
        config.vertex_size = sizeof(struct nk_gl2_vertex);
        config.vertex_alignment = NK_ALIGNOF(struct nk_gl2_vertex);
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
        nk_convert(&gl2.ctx, &dev->cmds, &vbuf, &ebuf, &config);

        /* setup vertex buffer pointer */
        {
            const void* vertices = nk_buffer_memory_const(&vbuf);
            glVertexPointer(2, GL_FLOAT, vs, (const void*)((const nk_byte*)vertices + vp));
            glTexCoordPointer(2, GL_FLOAT, vs, (const void*)((const nk_byte*)vertices + vt));
            glColorPointer(4, GL_UNSIGNED_BYTE, vs, (const void*)((const nk_byte*)vertices + vc));
        }

        /* iterate over and execute each draw command */
        offset = (const nk_draw_index*)nk_buffer_memory_const(&ebuf);
        nk_draw_foreach(cmd, &gl2.ctx, &dev->cmds)
        {
            if (!cmd->elem_count) continue;
            glBindTexture(GL_TEXTURE_2D, (GLuint)cmd->texture.id);
            glScissor(
                (GLint)(cmd->clip_rect.x * gl2.fb_scale.x),
                (GLint)((gl2.height - (GLint)(cmd->clip_rect.y + cmd->clip_rect.h)) * gl2.fb_scale.y),
                (GLint)(cmd->clip_rect.w * gl2.fb_scale.x),
                (GLint)(cmd->clip_rect.h * gl2.fb_scale.y));
            glDrawElements(GL_TRIANGLES, (GLsizei)cmd->elem_count, GL_UNSIGNED_SHORT, offset);
            offset += cmd->elem_count;
        }
        nk_clear(&gl2.ctx);
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
// マウスボタンのハンドリング用の関数を追加
NK_API void
nk_gl2_mouse_button_callback(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam)
{
    int x = GET_X_LPARAM(lParam);
    int y = GET_Y_LPARAM(lParam);
    
    if (msg == WM_LBUTTONDOWN) {
        double current_time = GetTickCount() / 1000.0;
        double dt = current_time - gl2.last_button_click;
        if (dt > NK_GL2_DOUBLE_CLICK_LO && dt < NK_GL2_DOUBLE_CLICK_HI) {
            gl2.is_double_click_down = nk_true;
            gl2.double_click_pos = nk_vec2((float)x, (float)y);
        }
        gl2.last_button_click = current_time;
    } else if (msg == WM_LBUTTONUP) {
        gl2.is_double_click_down = nk_false;
    }
}

// スクロールのハンドリング用の関数を追加
NK_API void
nk_gl2_scroll_callback(HWND hwnd, int delta)
{
    gl2.scroll.y += (float)(delta / WHEEL_DELTA);
}

// 文字入力のハンドリング用の関数を追加
NK_API void
nk_gl2_char_callback(HWND hwnd, UINT ch)
{
    if (ch >= 32) {
        nk_input_unicode(&gl2.ctx, (nk_rune)ch);
    }
}
NK_INTERN void
nk_gl2_clipboard_paste(nk_handle usr, struct nk_text_edit *edit)
{
    // Win32のクリップボード処理
    if (OpenClipboard(NULL)) {
        HANDLE data = GetClipboardData(CF_TEXT);
        if (data) {
            const char *text = (const char*)GlobalLock(data);
            if (text) {
                nk_textedit_paste(edit, text, nk_strlen(text));
                GlobalUnlock(data);
            }
        }
        CloseClipboard();
    }
    (void)usr;
}

NK_INTERN void
nk_gl2_clipboard_copy(nk_handle usr, const char *text, int len)
{
    // Win32のクリップボード処理
    if (OpenClipboard(NULL)) {
        HGLOBAL mem = GlobalAlloc(GMEM_MOVEABLE, (size_t)len + 1);
        if (mem) {
            char *str = (char*)GlobalLock(mem);
            if (str) {
                memcpy(str, text, (size_t)len);
                str[len] = '\0';
                GlobalUnlock(mem);
                SetClipboardData(CF_TEXT, mem);
            }
        }
        CloseClipboard();
    }
    (void)usr;
}

NK_API struct nk_context*
nk_gl2_init(enum nk_gl2_init_state init_state)
{
    (void)init_state;
    nk_init_default(&gl2.ctx, 0);
    // クリップボード関数の設定を追加
    gl2.ctx.clip.copy = nk_gl2_clipboard_copy;
    gl2.ctx.clip.paste = nk_gl2_clipboard_paste;
    gl2.ctx.clip.userdata = nk_handle_ptr(0);
    nk_buffer_init_default(&gl2.ogl.cmds);

    gl2.last_button_click = 0;
    gl2.scroll = nk_vec2(0, 0);
    gl2.is_double_click_down = nk_false;
    gl2.double_click_pos = nk_vec2(0, 0);

    return &gl2.ctx;
}

NK_API void
nk_gl2_font_stash_begin(struct nk_font_atlas** atlas)
{
    nk_font_atlas_init_default(&gl2.atlas);
    nk_font_atlas_begin(&gl2.atlas);
    *atlas = &gl2.atlas;
}

NK_API void
nk_gl2_font_stash_end(void)
{
    const void* image; int w, h;
    image = nk_font_atlas_bake(&gl2.atlas, &w, &h, NK_FONT_ATLAS_RGBA32);
    nk_gl2_device_upload_atlas(image, w, h);
    nk_font_atlas_end(&gl2.atlas, nk_handle_id((int)gl2.ogl.font_tex), &gl2.ogl.null);
    if (gl2.atlas.default_font)
        nk_style_set_font(&gl2.ctx, &gl2.atlas.default_font->handle);
}

NK_API void
nk_gl2_new_frame(void)
{
    struct nk_context* ctx = &gl2.ctx;

    nk_input_begin(ctx);
    nk_input_end(&gl2.ctx);
    gl2.text_len = 0;
    gl2.scroll = nk_vec2(0, 0);
}
NK_API int
nk_gl2_handle_event(HWND wnd, UINT msg, WPARAM wparam, LPARAM lparam)
{
    struct nk_context *ctx = &gl2.ctx;
    switch (msg)
    {
    case WM_SIZE:
    {
        unsigned width = LOWORD(lparam);
        unsigned height = HIWORD(lparam);
        if (width != gl2.width || height != gl2.height)
        {
            gl2.width = width;
            gl2.height = height;
            gl2.display_width = width;
            gl2.display_height = height;
        }
        break;
    }

    case WM_KEYDOWN:
    case WM_KEYUP:
    case WM_SYSKEYDOWN:
    case WM_SYSKEYUP:
    {
        int down = !((lparam >> 31) & 1);
        int ctrl = GetKeyState(VK_CONTROL) & (1 << 15);

        switch (wparam)
        {
        case VK_SHIFT:
        case VK_LSHIFT:
        case VK_RSHIFT:
            nk_input_key(ctx, NK_KEY_SHIFT, down);
            return 1;

        case VK_DELETE:
            nk_input_key(ctx, NK_KEY_DEL, down);
            return 1;

        case VK_RETURN:
            nk_input_key(ctx, NK_KEY_ENTER, down);
            return 1;

        case VK_TAB:
            nk_input_key(ctx, NK_KEY_TAB, down);
            return 1;

        case VK_LEFT:
            if (ctrl)
                nk_input_key(ctx, NK_KEY_TEXT_WORD_LEFT, down);
            else
                nk_input_key(ctx, NK_KEY_LEFT, down);
            return 1;

        case VK_RIGHT:
            if (ctrl)
                nk_input_key(ctx, NK_KEY_TEXT_WORD_RIGHT, down);
            else
                nk_input_key(ctx, NK_KEY_RIGHT, down);
            return 1;

        case VK_BACK:
            nk_input_key(ctx, NK_KEY_BACKSPACE, down);
            return 1;

        case VK_HOME:
            nk_input_key(ctx, NK_KEY_TEXT_START, down);
            nk_input_key(ctx, NK_KEY_SCROLL_START, down);
            return 1;

        case VK_END:
            nk_input_key(ctx, NK_KEY_TEXT_END, down);
            nk_input_key(ctx, NK_KEY_SCROLL_END, down);
            return 1;

        case VK_NEXT:
            nk_input_key(ctx, NK_KEY_SCROLL_DOWN, down);
            return 1;

        case VK_PRIOR:
            nk_input_key(ctx, NK_KEY_SCROLL_UP, down);
            return 1;

        case 'C':
            if (ctrl) {
                nk_input_key(ctx, NK_KEY_COPY, down);
                return 1;
            }
            break;

        case 'V':
            if (ctrl) {
                nk_input_key(ctx, NK_KEY_PASTE, down);
                return 1;
            }
            break;

        case 'X':
            if (ctrl) {
                nk_input_key(ctx, NK_KEY_CUT, down);
                return 1;
            }
            break;

        case 'Z':
            if (ctrl) {
                nk_input_key(ctx, NK_KEY_TEXT_UNDO, down);
                return 1;
            }
            break;

        case 'R':
            if (ctrl) {
                nk_input_key(ctx, NK_KEY_TEXT_REDO, down);
                return 1;
            }
            break;
        }
        return 0;
    }

    case WM_CHAR:
        if (wparam >= 32)
        {
            nk_input_unicode(ctx, (nk_rune)wparam);
            return 1;
        }
        break;

    case WM_LBUTTONDOWN:
        {
            int x = GET_X_LPARAM(lparam);
            int y = GET_Y_LPARAM(lparam);
            nk_input_button(ctx, NK_BUTTON_LEFT, x, y, 1);
            SetCapture(wnd);
            double current_time = GetTickCount() / 1000.0;
            if ((current_time - gl2.last_button_click) < 0.2) {
                nk_input_button(ctx, NK_BUTTON_DOUBLE, x, y, 1);
            }
            gl2.last_button_click = current_time;
            return 1;
        }

    case WM_LBUTTONUP:
        {
            int x = GET_X_LPARAM(lparam);
            int y = GET_Y_LPARAM(lparam);
            nk_input_button(ctx, NK_BUTTON_LEFT, x, y, 0);
            nk_input_button(ctx, NK_BUTTON_DOUBLE, x, y, 0);
            ReleaseCapture();
            return 1;
        }

    case WM_RBUTTONDOWN:
        nk_input_button(ctx, NK_BUTTON_RIGHT, (short)LOWORD(lparam), (short)HIWORD(lparam), 1);
        SetCapture(wnd);
        return 1;

    case WM_RBUTTONUP:
        nk_input_button(ctx, NK_BUTTON_RIGHT, (short)LOWORD(lparam), (short)HIWORD(lparam), 0);
        ReleaseCapture();
        return 1;

    case WM_MBUTTONDOWN:
        nk_input_button(ctx, NK_BUTTON_MIDDLE, (short)LOWORD(lparam), (short)HIWORD(lparam), 1);
        SetCapture(wnd);
        return 1;

    case WM_MBUTTONUP:
        nk_input_button(ctx, NK_BUTTON_MIDDLE, (short)LOWORD(lparam), (short)HIWORD(lparam), 0);
        ReleaseCapture();
        return 1;
    case WM_MOUSEMOVE:
    {
        int x = GET_X_LPARAM(lparam);
        int y = GET_Y_LPARAM(lparam);
        nk_input_motion(ctx, x, y);

        // ドラッグ処理
        if (wparam & MK_LBUTTON) {
            nk_input_button(ctx, NK_BUTTON_LEFT, x, y, 1);
        }
        return 1;
    }
    case WM_MOUSEWHEEL:
        nk_input_scroll(ctx, nk_vec2(0,(float)(short)HIWORD(wparam) / WHEEL_DELTA));
        return 1;
    case WM_CAPTURECHANGED:
        if ((HWND)lparam != wnd)
        {
            nk_input_button(&gl2.ctx, NK_BUTTON_LEFT, 0, 0, 0);
            nk_input_button(&gl2.ctx, NK_BUTTON_MIDDLE, 0, 0, 0);
            nk_input_button(&gl2.ctx, NK_BUTTON_RIGHT, 0, 0, 0);
        }
        return 1;

    case WM_LBUTTONDBLCLK:
        nk_input_button(ctx, NK_BUTTON_DOUBLE, (short)LOWORD(lparam), (short)HIWORD(lparam), 1);
        return 1;
    }

    return 0;
}
NK_API void
nk_gl2_shutdown(void)
{
    struct nk_gl2_device* dev = &gl2.ogl;
    nk_font_atlas_clear(&gl2.atlas);
    nk_free(&gl2.ctx);
    glDeleteTextures(1, &dev->font_tex);
    nk_buffer_free(&dev->cmds);
    memset(&gl2, 0, sizeof(gl2));
}

#endif
