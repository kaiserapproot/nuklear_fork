#pragma once
/*
 * Nuklear - v1.32.0 - public domain
 * no warrenty implied; use at your own risk.
 * authored from 2015-2017 by Micha Mettke
 * 
 * OpenGL ES 1.1対応版 - iOS向けに修正
 */
 /*
  * ==============================================================
  *
  *                              API
  *
  * ===============================================================
  */
#ifndef NK_GLES1_H_
#define NK_GLES1_H_

// iOS向けインクルード
#include <OpenGLES/ES1/gl.h>
#include <OpenGLES/ES1/glext.h>

NK_API struct nk_context* nk_gles1_init(void* font, int width, int height);
NK_API void nk_gles1_font_stash_begin(struct nk_font_atlas** atlas);
NK_API void nk_gles1_font_stash_end(void);

NK_API void nk_gles1_render(enum nk_anti_aliasing);
NK_API void nk_gles1_shutdown(void);

// ビューポート設定
NK_API void nk_gles1_viewport(int width, int height);

#endif

/*
 * ==============================================================
 *
 *                          IMPLEMENTATION
 *
 * ===============================================================
 */
#ifdef NK_GLES1_IMPLEMENTATION

#ifndef NK_GLES1_TEXT_MAX
#define NK_GLES1_TEXT_MAX 256
#endif
#ifndef NK_GLES1_DOUBLE_CLICK_LO
#define NK_GLES1_DOUBLE_CLICK_LO 0.02
#endif
#ifndef NK_GLES1_DOUBLE_CLICK_HI
#define NK_GLES1_DOUBLE_CLICK_HI 0.2
#endif

struct nk_gles1_device
{
    struct nk_buffer cmds;
    struct nk_draw_null_texture null;
    GLuint font_tex;
};

struct nk_gles1_vertex
{
    float position[2];
    float uv[2];
    nk_byte col[4];
};

static struct nk_gles1
{
    int width, height;
    int display_width, display_height;
    struct nk_gles1_device ogl;
    struct nk_context ctx;
    struct nk_font_atlas atlas;
    struct nk_vec2 fb_scale;
    unsigned int text[NK_GLES1_TEXT_MAX];
    int text_len;
    struct nk_vec2 scroll;
    double last_button_click;
    int is_double_click_down;
    struct nk_vec2 double_click_pos;
} gles1;

NK_INTERN void
nk_gles1_device_upload_atlas(const void* image, int width, int height)
{
    struct nk_gles1_device* dev = &gles1.ogl;
    glGenTextures(1, &dev->font_tex);
    glBindTexture(GL_TEXTURE_2D, dev->font_tex);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)width, (GLsizei)height, 0,
        GL_RGBA, GL_UNSIGNED_BYTE, image);
}

NK_API void
nk_gles1_render(enum nk_anti_aliasing AA)
{
    /* setup global state */
    struct nk_gles1_device* dev = &gles1.ogl;
    
    // OpenGL ES 1.1向けに状態保存方法を変更（glPushAttribがないため個別に保存）
    GLboolean cull_face_enabled = glIsEnabled(GL_CULL_FACE);
    GLboolean depth_test_enabled = glIsEnabled(GL_DEPTH_TEST);
    GLboolean scissor_test_enabled = glIsEnabled(GL_SCISSOR_TEST);
    GLboolean blend_enabled = glIsEnabled(GL_BLEND);
    GLboolean texture_2d_enabled = glIsEnabled(GL_TEXTURE_2D);
    GLint blend_src, blend_dst;
    glGetIntegerv(GL_BLEND_SRC, &blend_src);
    glGetIntegerv(GL_BLEND_DST, &blend_dst);
    
    // クライアント状態の保存
    GLboolean vertex_array_enabled = glIsEnabled(GL_VERTEX_ARRAY);
    GLboolean tex_coord_array_enabled = glIsEnabled(GL_TEXTURE_COORD_ARRAY);
    GLboolean color_array_enabled = glIsEnabled(GL_COLOR_ARRAY);
    
    // 行列モード保存
    GLint matrix_mode;
    glGetIntegerv(GL_MATRIX_MODE, &matrix_mode);
    
    // プロジェクション行列保存
    glMatrixMode(GL_PROJECTION);
    glPushMatrix();
    
    // モデルビュー行列保存
    glMatrixMode(GL_MODELVIEW);
    glPushMatrix();
    
    // レンダリング状態設定
    glDisable(GL_CULL_FACE);
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_SCISSOR_TEST);
    glEnable(GL_BLEND);
    glEnable(GL_TEXTURE_2D);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    /* setup viewport/project */
    glViewport(0, 0, (GLsizei)gles1.display_width, (GLsizei)gles1.display_height);
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    // UIKit座標系に合わせて座標系を設定（左上原点）
    glOrthof(0.0f, gles1.width, gles1.height, 0.0f, -1.0f, 1.0f);
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glEnableClientState(GL_COLOR_ARRAY);
    {
        GLsizei vs = sizeof(struct nk_gles1_vertex);
        size_t vp = offsetof(struct nk_gles1_vertex, position);
        size_t vt = offsetof(struct nk_gles1_vertex, uv);
        size_t vc = offsetof(struct nk_gles1_vertex, col);

        /* convert from command queue into draw list and draw to screen */
        const struct nk_draw_command* cmd;
        const nk_draw_index* offset = NULL;
        struct nk_buffer vbuf, ebuf;

        /* fill convert configuration */
        struct nk_convert_config config;
        static const struct nk_draw_vertex_layout_element vertex_layout[] = {
            {NK_VERTEX_POSITION, NK_FORMAT_FLOAT, NK_OFFSETOF(struct nk_gles1_vertex, position)},
            {NK_VERTEX_TEXCOORD, NK_FORMAT_FLOAT, NK_OFFSETOF(struct nk_gles1_vertex, uv)},
            {NK_VERTEX_COLOR, NK_FORMAT_R8G8B8A8, NK_OFFSETOF(struct nk_gles1_vertex, col)},
            {NK_VERTEX_LAYOUT_END}
        };
        NK_MEMSET(&config, 0, sizeof(config));
        config.vertex_layout = vertex_layout;
        config.vertex_size = sizeof(struct nk_gles1_vertex);
        config.vertex_alignment = NK_ALIGNOF(struct nk_gles1_vertex);
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
        nk_convert(&gles1.ctx, &dev->cmds, &vbuf, &ebuf, &config);

        /* setup vertex buffer pointer */
        {
            const void* vertices = nk_buffer_memory_const(&vbuf);
            glVertexPointer(2, GL_FLOAT, vs, (const void*)((const nk_byte*)vertices + vp));
            glTexCoordPointer(2, GL_FLOAT, vs, (const void*)((const nk_byte*)vertices + vt));
            glColorPointer(4, GL_UNSIGNED_BYTE, vs, (const void*)((const nk_byte*)vertices + vc));
        }

        /* iterate over and execute each draw command */
        offset = (const nk_draw_index*)nk_buffer_memory_const(&ebuf);
        nk_draw_foreach(cmd, &gles1.ctx, &dev->cmds)
        {
            if (!cmd->elem_count) continue;
            glBindTexture(GL_TEXTURE_2D, (GLuint)cmd->texture.id);
            glScissor(
                (GLint)(cmd->clip_rect.x * gles1.fb_scale.x),
                (GLint)((gles1.height - (GLint)(cmd->clip_rect.y + cmd->clip_rect.h)) * gles1.fb_scale.y),
                (GLint)(cmd->clip_rect.w * gles1.fb_scale.x),
                (GLint)(cmd->clip_rect.h * gles1.fb_scale.y));
            glDrawElements(GL_TRIANGLES, (GLsizei)cmd->elem_count, GL_UNSIGNED_SHORT, offset);
            offset += cmd->elem_count;
        }
        nk_clear(&gles1.ctx);
        nk_buffer_free(&vbuf);
        nk_buffer_free(&ebuf);
    }

    /* 状態を元に戻す */
    if (!vertex_array_enabled) glDisableClientState(GL_VERTEX_ARRAY);
    if (!tex_coord_array_enabled) glDisableClientState(GL_TEXTURE_COORD_ARRAY);
    if (!color_array_enabled) glDisableClientState(GL_COLOR_ARRAY);

    if (!cull_face_enabled) glDisable(GL_CULL_FACE);
    else glEnable(GL_CULL_FACE);
    
    if (!depth_test_enabled) glDisable(GL_DEPTH_TEST);
    else glEnable(GL_DEPTH_TEST);
    
    if (!scissor_test_enabled) glDisable(GL_SCISSOR_TEST);
    else glEnable(GL_SCISSOR_TEST);
    
    if (!blend_enabled) glDisable(GL_BLEND);
    else glEnable(GL_BLEND);
    
    if (!texture_2d_enabled) glDisable(GL_TEXTURE_2D);
    else glEnable(GL_TEXTURE_2D);
    
    glBlendFunc(blend_src, blend_dst);
    
    glBindTexture(GL_TEXTURE_2D, 0);
    
    // 行列を元に戻す
    glMatrixMode(GL_MODELVIEW);
    glPopMatrix();
    glMatrixMode(GL_PROJECTION);
    glPopMatrix();
    glMatrixMode(matrix_mode);
}

// iOS用クリップボード関数
NK_INTERN void
nk_gles1_clipboard_paste(nk_handle usr, struct nk_text_edit *edit)
{
    // UIPasteboardを使用したクリップボード内容の取得
    NSString *string = [UIPasteboard generalPasteboard].string;
    if (string) {
        const char *utf8 = [string UTF8String];
        nk_textedit_paste(edit, utf8, nk_strlen(utf8));
    }
}

NK_INTERN void
nk_gles1_clipboard_copy(nk_handle usr, const char *text, int len)
{
    // UIPasteboardにテキストをコピー
    if (len > 0) {
        NSString *string = [[NSString alloc] initWithBytes:text
                                                   length:len
                                                 encoding:NSUTF8StringEncoding];
        [UIPasteboard generalPasteboard].string = string;
    }
}

NK_API struct nk_context*
nk_gles1_init(void* font, int width, int height)
{
    gles1.width = width;
    gles1.height = height;
    gles1.display_width = width;
    gles1.display_height = height;
    gles1.fb_scale.x = 1.0f;
    gles1.fb_scale.y = 1.0f;
    
    nk_init_default(&gles1.ctx, font);
    gles1.ctx.clip.copy = nk_gles1_clipboard_copy;
    gles1.ctx.clip.paste = nk_gles1_clipboard_paste;
    gles1.ctx.clip.userdata = nk_handle_ptr(0);
    nk_buffer_init_default(&gles1.ogl.cmds);

    gles1.last_button_click = 0;
    gles1.is_double_click_down = nk_false;
    gles1.double_click_pos = nk_vec2(0, 0);
    gles1.scroll = nk_vec2(0, 0);

    return &gles1.ctx;
}

NK_API void
nk_gles1_font_stash_begin(struct nk_font_atlas** atlas)
{
    nk_font_atlas_init_default(&gles1.atlas);
    nk_font_atlas_begin(&gles1.atlas);
    *atlas = &gles1.atlas;
}

NK_API void
nk_gles1_font_stash_end(void)
{
    const void* image; int w, h;
    image = nk_font_atlas_bake(&gles1.atlas, &w, &h, NK_FONT_ATLAS_RGBA32);
    nk_gles1_device_upload_atlas(image, w, h);
    nk_font_atlas_end(&gles1.atlas, nk_handle_id((int)gles1.ogl.font_tex), &gles1.ogl.null);
    if (gles1.atlas.default_font)
        nk_style_set_font(&gles1.ctx, &gles1.atlas.default_font->handle);
}

// ビューポート設定
NK_API void
nk_gles1_viewport(int width, int height)
{
    gles1.width = width;
    gles1.height = height;
    gles1.display_width = width;
    gles1.display_height = height;
    gles1.fb_scale.x = 1.0f;
    gles1.fb_scale.y = 1.0f;
}

NK_API void
nk_gles1_shutdown(void)
{
    struct nk_gles1_device* dev = &gles1.ogl;
    nk_font_atlas_clear(&gles1.atlas);
    nk_free(&gles1.ctx);
    glDeleteTextures(1, &dev->font_tex);
    nk_buffer_free(&dev->cmds);
    memset(&gles1, 0, sizeof(gles1));
}

#endif // NK_GLES1_IMPLEMENTATION