#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>

// macOS向けインクルード
#include <OpenGL/gl.h>
#include <OpenGL/glu.h>
#include <time.h>
#include "nuklear_gl.h"
#include "atlas.inl"

// デバッグログ関数
static void debug_log(const char* format, ...) {
    char buffer[1024];
    va_list args;
    va_start(args, format);
    vsnprintf(buffer, sizeof(buffer), format, args);
    va_end(args);
    fprintf(stderr, "%s\n", buffer);
}

int BUFFER_SIZE = 163840; // 変数にする

static GLfloat* tex_buf;
static GLfloat* vert_buf;
static GLubyte* color_buf;
static GLuint* index_buf;
static GLuint* precomputed_indices = NULL;

int width = 800;
int height = 600;
static int buf_idx;

// バッファを初期化する関数
static void init_buffers() {
    tex_buf = malloc(BUFFER_SIZE * 8 * sizeof(GLfloat));
    vert_buf = malloc(BUFFER_SIZE * 8 * sizeof(GLfloat));
    color_buf = malloc(BUFFER_SIZE * 16 * sizeof(GLubyte));
    index_buf = malloc(BUFFER_SIZE * 6 * sizeof(GLuint));
}

// バッファを解放する関数
static void free_buffers() {
    free(tex_buf);
    free(vert_buf);
    free(color_buf);
    free(index_buf);
}

// インデックスバッファの事前計算
static void init_indices() {
    int i, idx, vertex;
    if (!precomputed_indices) {
        precomputed_indices = malloc(BUFFER_SIZE * 6 * sizeof(GLuint));
        for (i = 0; i < BUFFER_SIZE; i++) {
            idx = i * 6;
            vertex = i * 4;
            precomputed_indices[idx + 0] = vertex + 0;
            precomputed_indices[idx + 1] = vertex + 1;
            precomputed_indices[idx + 2] = vertex + 2;
            precomputed_indices[idx + 3] = vertex + 2;
            precomputed_indices[idx + 4] = vertex + 3;
            precomputed_indices[idx + 5] = vertex + 1;
        }
    }
}

/**
 * @brief OpenGLの初期化を行う関数
 *
 * この関数は、OpenGLの初期化、インデックスバッファの初期化、
 * バッファの初期化、およびテクスチャの初期化を行います。
 */
void r_init(void)
{
    GLuint id;

    // ブレンディングを有効化し、ブレンディング関数を設定
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);

    // カリングを無効化
    glDisable(GL_CULL_FACE);

    // 深度テストを無効化
    glDisable(GL_DEPTH_TEST);

    // シザーテストを有効化
    glEnable(GL_SCISSOR_TEST);

    // テクスチャマッピングを有効化
    glEnable(GL_TEXTURE_2D);

    // 頂点配列を有効化
    glEnableClientState(GL_VERTEX_ARRAY);

    // テクスチャ座標配列を有効化
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);

    // カラー配列を有効化
    glEnableClientState(GL_COLOR_ARRAY);

    // インデックスバッファの初期化
    init_indices();

    // バッファの初期化
    init_buffers();

    // テクスチャの初期化
    glGenTextures(1, &id);
    glBindTexture(GL_TEXTURE_2D, id);

    // テクスチャフォーマットをアルファ値付きに変更
    glTexImage2D(GL_TEXTURE_2D, 0, GL_ALPHA, ATLAS_WIDTH, ATLAS_HEIGHT, 0,
        GL_ALPHA, GL_UNSIGNED_BYTE, atlas_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP);
}

/**
 * @brief バッファの内容を描画する関数
 *
 * この関数は、バッファに蓄積された頂点データ、テクスチャ座標データ、
 * カラーデータを使用して描画を行います。描画後、バッファのインデックスをリセットします。
 */
static void flush(void)
{
    // バッファにデータがない場合は何もしない
    if (buf_idx == 0) { return; }

    // OpenGLステート設定
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
    glEnable(GL_TEXTURE_2D);

    // 投影行列設定
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0.0f, width, height, 0.0f, -1.0f, +1.0f);

    // モデルビュー行列をリセット
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    // 描画実行
    glEnableClientState(GL_VERTEX_ARRAY);
    glEnableClientState(GL_TEXTURE_COORD_ARRAY);
    glEnableClientState(GL_COLOR_ARRAY);

    // 頂点配列、テクスチャ座標配列、カラー配列のポインタを設定
    glTexCoordPointer(2, GL_FLOAT, 0, tex_buf);
    glVertexPointer(2, GL_FLOAT, 0, vert_buf);
    glColorPointer(4, GL_UNSIGNED_BYTE, 0, color_buf);
    
    // インデックスバッファを使用して描画
    glDrawElements(GL_TRIANGLES, buf_idx * 6, GL_UNSIGNED_INT, index_buf);

    // バッファのインデックスをリセット
    buf_idx = 0;
}

/**
 * @brief 四角形をバッファに追加する関数
 *
 * この関数は、指定された四角形の頂点データ、テクスチャ座標データ、
 * カラーデータをバッファに追加します。バッファが満杯の場合は描画を行います。
 *
 * @param dst 描画先の矩形
 * @param src テクスチャの矩形
 * @param color 描画する色
 */
static void push_quad(mu_Rect dst, mu_Rect src, mu_Color color)
{
    int texvert_idx = buf_idx * 8; // テクスチャ座標と頂点座標のインデックス
    int color_idx = buf_idx * 16;  // カラーのインデックス
    int index_idx = buf_idx * 6;   // インデックスバッファのインデックス
    int i;
    float x, y, w, h;

    GLubyte* color_ptr = &color_buf[color_idx];
    GLfloat* v = &vert_buf[texvert_idx];
    GLfloat* t = &tex_buf[texvert_idx];

    // バッファが満杯の場合は描画を行う
    if (buf_idx == BUFFER_SIZE)
    {
        flush();
    }

    // カラーバッファの一括設定
    for (i = 0; i < 4; i++)
    {
        *color_ptr++ = color.r;
        *color_ptr++ = color.g;
        *color_ptr++ = color.b;
        *color_ptr++ = color.a;
    }

    // テクスチャ座標の計算
    x = (float)src.x / ATLAS_WIDTH;
    y = (float)src.y / ATLAS_HEIGHT;
    w = (float)src.w / ATLAS_WIDTH;
    h = (float)src.h / ATLAS_HEIGHT;

    // 頂点座標の設定
    v[0] = (float)dst.x;        v[1] = (float)dst.y;
    v[2] = (float)(dst.x + dst.w); v[3] = (float)dst.y;
    v[4] = (float)dst.x;        v[5] = (float)(dst.y + dst.h);
    v[6] = (float)(dst.x + dst.w); v[7] = (float)(dst.y + dst.h);

    // テクスチャ座標の設定
    t[0] = x;     t[1] = y;
    t[2] = x + w; t[3] = y;
    t[4] = x;     t[5] = y + h;
    t[6] = x + w; t[7] = y + h;

    // インデックスバッファの更新
    memcpy(&index_buf[index_idx], &precomputed_indices[index_idx], 6 * sizeof(GLuint));

    // バッファインデックスをインクリメント
    buf_idx++;
}

/**
 * @brief 四角形を描画する関数
 *
 * この関数は、指定された四角形を描画します。
 *
 * @param rect 描画する四角形
 * @param color 描画する色
 */
void r_draw_rect(mu_Rect rect, mu_Color color) {
    push_quad(rect, atlas[ATLAS_WHITE], color);
}

void r_shutdown(void) {
    if (precomputed_indices) {
        free(precomputed_indices);
        precomputed_indices = NULL;
    }

    /* バッファの解放 */
    free_buffers();
}

void r_draw_text(const char* text, mu_Vec2 pos, mu_Color color) {
    const char* p;
    int chr;
    mu_Rect src;
    mu_Rect dst = { pos.x, pos.y, 0, 0 };
    for (p = text; *p; p++) {
        if ((*p & 0xc0) == 0x80) { continue; }
        chr = mu_min((unsigned char)*p, 127);
        src = atlas[ATLAS_FONT + chr];
        dst.w = src.w;
        dst.h = src.h;
        push_quad(dst, src, color);
        dst.x += dst.w;
    }
}

void r_draw_icon(int id, mu_Rect rect, mu_Color color) {
    mu_Rect src = atlas[id];
    int x = rect.x + (rect.w - src.w) / 2;
    int y = rect.y + (rect.h - src.h) / 2;
    push_quad(mu_rect(x, y, src.w, src.h), src, color);
}

int r_get_text_width(const char* text, int len) {
    int chr;
    int res;
    const char* p;
    res = 0;
    for (p = text; *p && len--; p++) {
        if ((*p & 0xc0) == 0x80) { continue; }
        chr = mu_min((unsigned char)*p, 127);
        res += atlas[ATLAS_FONT + chr].w;
    }
    return res;
}

int r_get_text_height(void) {
    return 18;
}

void r_set_clip_rect(mu_Rect rect) {
    int viewport_height = height;
    flush();
    glScissor(rect.x, viewport_height - (rect.y + rect.h), rect.w, rect.h);
}

void r_clear(mu_Color clr) {
    flush();
    glClearColor(clr.r / 255.0f, clr.g / 255.0f, clr.b / 255.0f, clr.a / 255.0f);
    glClear(GL_COLOR_BUFFER_BIT);
}

/**
 * @brief 描画内容を画面に表示する関数
 *
 * この関数は、バッファの内容を描画し、画面に表示します。
 * 描画後、ビューポートと行列をリセットします。
 */
void r_present(void)
{
    // バッファの内容を描画
    flush();

    // ビューポートを設定
    glViewport(0, 0, width, height);

    // 投影行列をリセットし、正射影行列を設定
    glMatrixMode(GL_PROJECTION);
    glLoadIdentity();
    glOrtho(0.0f, width, height, 0.0f, -1.0f, +1.0f);

    // モデルビュー行列をリセット
    glMatrixMode(GL_MODELVIEW);
    glLoadIdentity();

    // 描画の完了を待つ
    glFinish();
    
    // macOSではSwapBuffersの代わりにNSOpenGLContextのflushBufferを使用する必要があります
    // このメソッドは呼び出し側のコードで実行されると仮定します
}

void resize_buffers(int new_width, int new_height) {
    BUFFER_SIZE = (new_width * new_height) / 4;
    free_buffers();
    init_buffers();
    
    width = new_width;
    height = new_height;
}
