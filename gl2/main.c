/* nuklear - v1.32.0 - public domain */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdarg.h>
#include <string.h>
#include <math.h>
#include <assert.h>
#include <limits.h>
#include <time.h>
#include <windows.h>
#include <GL/gl.h>
#include <GL/glu.h>

#define NK_INCLUDE_FIXED_TYPES
#define NK_INCLUDE_STANDARD_IO
#define NK_INCLUDE_STANDARD_VARARGS
#define NK_INCLUDE_DEFAULT_ALLOCATOR
#define NK_INCLUDE_VERTEX_BUFFER_OUTPUT
#define NK_INCLUDE_FONT_BAKING
#define NK_INCLUDE_DEFAULT_FONT
#define NK_IMPLEMENTATION
#define NK_GL2_IMPLEMENTATION
#define NK_KEYSTATE_BASED_INPUT
#include "../nuklear.h"
#include "nuklear_gl2.h"

#define WINDOW_WIDTH 1200
#define WINDOW_HEIGHT 800

/* ===============================================================
 *
 *                          EXAMPLE
 *
 * ===============================================================*/
 /* このライブラリでできることの概要を提供するためのコード例です。例を試すには、以下の定義をコメント解除してください */
 /*#define INCLUDE_ALL */
 /*#define INCLUDE_STYLE */
 /*#define INCLUDE_CALCULATOR */
 //#define INCLUDE_OVERVIEW
 /*#define INCLUDE_NODE_EDITOR */

#ifdef INCLUDE_ALL
#define INCLUDE_STYLE
#define INCLUDE_CALCULATOR
#define INCLUDE_OVERVIEW
#define INCLUDE_NODE_EDITOR
#endif

#ifdef INCLUDE_STYLE
#include "../style.c"
#endif
#ifdef INCLUDE_CALCULATOR
#include "../calculator.c"
#endif
#ifdef INCLUDE_OVERVIEW
#include "../overview.c"
#endif
#ifdef INCLUDE_NODE_EDITOR
#include "../node_editor.c"
#endif

/* ===============================================================
 *
 *                          DEMO
 *
 * ===============================================================*/
static struct nk_gl2 gl2;
static struct nk_context* ctx;  // グローバル変数として追加
void check_gl_error(const char* stmt, const char* fname, int line)
{
	GLenum err = glGetError();
	if (err != GL_NO_ERROR)
	{
		fprintf(stderr, "OpenGL error 0x%04X, at %s:%i - for %s\n", err, fname, line, stmt);
		exit(1);
	}
}
static LRESULT CALLBACK WindowProc(HWND hwnd, UINT uMsg, WPARAM wParam, LPARAM lParam)
{
    // Nuklearのイベントハンドラを呼び出す
    if (nk_gl2_handle_event(hwnd, uMsg, wParam, lParam))
        return 0;

    switch (uMsg)
    {
    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }

    return DefWindowProc(hwnd, uMsg, wParam, lParam);
}


#define GL_CHECK(stmt) do { \
    stmt; \
    check_gl_error(#stmt, __FILE__, __LINE__); \
} while (0)

int main(void)
{
	/* Platform */
	HINSTANCE hInstance = GetModuleHandle(NULL);
	WNDCLASS wc = { 0 };
	HWND hwnd;
	HDC hdc;
	HGLRC hglrc;
	MSG msg;
	int running = 1;
	struct nk_colorf bg;

	/* Win32 */
	wc.style = CS_HREDRAW | CS_VREDRAW | CS_OWNDC;
	wc.lpfnWndProc = WindowProc;
	wc.hInstance = hInstance;
	wc.lpszClassName = "NuklearWindowClass";
	if (!RegisterClass(&wc))
	{
		fprintf(stderr, "ウィンドウクラスの登録に失敗しました: %lu\n", GetLastError());
		return -1;
	}

	hwnd = CreateWindowEx(0, wc.lpszClassName, "Demo",
		WS_OVERLAPPEDWINDOW | WS_VISIBLE,
		CW_USEDEFAULT, CW_USEDEFAULT,
		WINDOW_WIDTH, WINDOW_HEIGHT,
		NULL, NULL, hInstance, NULL);

	if (!hwnd)
	{
		fprintf(stderr, "ウィンドウの作成に失敗しました: %lu\n", GetLastError());
		return -1;
	}

	hdc = GetDC(hwnd);
	if (!hdc)
	{
		fprintf(stderr, "デバイスコンテキストの取得に失敗しました: %lu\n", GetLastError());
		return -1;
	}

	{
		int format;
		PIXELFORMATDESCRIPTOR pfd = {
			sizeof(PIXELFORMATDESCRIPTOR),    // サイズ
			1,                                // バージョン
			PFD_DRAW_TO_WINDOW |             // ウィンドウ
			PFD_SUPPORT_OPENGL |             // OpenGL
			PFD_DOUBLEBUFFER,                // ダブルバッファ
			PFD_TYPE_RGBA,                   // RGBA タイプ
			32,                              // 24-bit カラー深度
			0, 0, 0, 0, 0, 0,               // カラービットを無視
			0,                              // アルファバッファなし
			0,                              // シフトビットを無視
			0,                              // アキュムレーションバッファなし
			0, 0, 0, 0,                     // アキュムレーションビットを無視
			24,                             // 16-bit Z-バッファ
			8,                              // ステンシルバッファ
			0,                              // 補助バッファなし
			PFD_MAIN_PLANE,                 // メインレイヤー
			0,                              // 予約済み
			0, 0, 0                         // レイヤーマスクを無視
		};

		format = ChoosePixelFormat(hdc, &pfd);
		if (format == 0)
		{
			fprintf(stderr, "ピクセルフォーマットの選択に失敗しました: %lu\n", GetLastError());
			return -1;
		}

		if (!SetPixelFormat(hdc, format, &pfd))
		{
			fprintf(stderr, "ピクセルフォーマットの設定に失敗しました: %lu\n", GetLastError());
			return -1;
		}

		// OpenGLエラーのチェック（OpenGLではなくWin32 APIのエラーを確認）
		UINT gle = GetLastError();
		if (gle != 0)
		{
			fprintf(stderr, "SetPixelFormat の呼び出し後にエラーが発生しました: %lu\n", gle);
			return -1;
		}

		hglrc = wglCreateContext(hdc);
		if (!hglrc)
		{
			fprintf(stderr, "OpenGLコンテキストの作成に失敗しました: %lu\n", GetLastError());
			return -1;
		}

		if (!wglMakeCurrent(hdc, hglrc))
		{
			fprintf(stderr, "OpenGLコンテキストの設定に失敗しました: %lu\n", GetLastError());
			return -1;
		}
		check_gl_error("wglMakeCurrent", __FILE__, __LINE__);
		// OpenGL初期設定
		glEnable(GL_BLEND);
		glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
		glViewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);
		// OpenGL初期設定（wglMakeCurrent後）
		GL_CHECK(glEnable(GL_BLEND));
		GL_CHECK(glEnable(GL_TEXTURE_2D));
		GL_CHECK(glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA));
		GL_CHECK(glEnable(GL_CULL_FACE));
		GL_CHECK(glCullFace(GL_BACK));
		GL_CHECK(glFrontFace(GL_CCW));  // 反時計回りを表向きに設定
		// OpenGL初期設定（wglMakeCurrent後）
		GL_CHECK(glShadeModel(GL_SMOOTH));
		GL_CHECK(glPixelStorei(GL_UNPACK_ALIGNMENT, 1));
		GL_CHECK(glDisable(GL_DEPTH_TEST));
		GL_CHECK(glDisable(GL_CULL_FACE));
		GL_CHECK(glEnable(GL_BLEND));
		GL_CHECK(glEnable(GL_TEXTURE_2D));
		GL_CHECK(glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA));
	}

	/* GUI */
	/* GUI */
	ctx = nk_gl2_init(NK_GL2_DEFAULT);
	if (!ctx)
	{
		fprintf(stderr, "Nuklearコンテキストの初期化に失敗しました\n");
		return -1;
	}

	// gl2構造体の初期化を追加
	gl2.width = WINDOW_WIDTH;
	gl2.height = WINDOW_HEIGHT;
	gl2.display_width = WINDOW_WIDTH;
	gl2.display_height = WINDOW_HEIGHT;
	gl2.fb_scale = nk_vec2(1.0f, 1.0f);

	/* フォントの読み込み（必要に応じて） */
	{
		struct nk_font_atlas* atlas;
		nk_gl2_font_stash_begin(&atlas);
		/* フォントの追加例 */
		/* struct nk_font *droid = nk_font_atlas_add_from_file(atlas, "../../../extra_font/DroidSans.ttf", 14, 0); */
		nk_gl2_font_stash_end();
		/* nk_style_load_all_cursors(ctx, atlas->cursors); */
		/* nk_style_set_font(ctx, &droid->handle); */
	}

#ifdef INCLUDE_STYLE
	/* テーマの設定例 */
	/* set_style(ctx, THEME_WHITE); */
	/* set_style(ctx, THEME_RED); */
	/* set_style(ctx, THEME_BLUE); */
	/* set_style(ctx, THEME_DARK); */
#endif

	/* 背景色の初期化 */
	bg.r = 0.10f;
	bg.g = 0.18f;
	bg.b = 0.24f;
	bg.a = 1.0f;

	while (running)
	{
        // Input
        nk_input_begin(ctx);
        {
            MSG msg;
            while (PeekMessage(&msg, NULL, 0, 0, PM_REMOVE))
            {
                if (msg.message == WM_QUIT)
                {
                    running = 0;
                    break;
                }
                TranslateMessage(&msg);
                DispatchMessage(&msg);
            }

            // マウスの位置を取得して更新
            POINT pos;
            GetCursorPos(&pos);
            ScreenToClient(hwnd, &pos);
            nk_input_motion(ctx, pos.x, pos.y);
        }
        nk_input_end(ctx);

		/* GUI */
		if (nk_begin(ctx, "Demo", nk_rect(50, 50, 230, 250),
			NK_WINDOW_BORDER | NK_WINDOW_MOVABLE | NK_WINDOW_SCALABLE |
			NK_WINDOW_MINIMIZABLE | NK_WINDOW_TITLE))
		{
			enum { EASY, HARD };
			static int op = EASY;
			static int property = 20;
			nk_layout_row_static(ctx, 30, 80, 1);
			if (nk_button_label(ctx, "button"))
				fprintf(stdout, "button pressed\n");

			nk_layout_row_dynamic(ctx, 30, 2);
			if (nk_option_label(ctx, "easy", op == EASY)) op = EASY;
			if (nk_option_label(ctx, "hard", op == HARD)) op = HARD;

			nk_layout_row_dynamic(ctx, 25, 1);
			nk_property_int(ctx, "Compression:", 0, &property, 100, 10, 1);

			nk_layout_row_dynamic(ctx, 20, 1);
			nk_label(ctx, "background:", NK_TEXT_LEFT);
			nk_layout_row_dynamic(ctx, 25, 1);
			if (nk_combo_begin_color(ctx, nk_rgb_cf(bg), nk_vec2(nk_widget_width(ctx), 400)))
			{
				nk_layout_row_dynamic(ctx, 120, 1);
				bg = nk_color_picker(ctx, bg, NK_RGBA);
				nk_layout_row_dynamic(ctx, 25, 1);
				bg.r = nk_propertyf(ctx, "#R:", 0, bg.r, 1.0f, 0.01f, 0.005f);
				bg.g = nk_propertyf(ctx, "#G:", 0, bg.g, 1.0f, 0.01f, 0.005f);
				bg.b = nk_propertyf(ctx, "#B:", 0, bg.b, 1.0f, 0.01f, 0.005f);
				bg.a = nk_propertyf(ctx, "#A:", 0, bg.a, 1.0f, 0.01f, 0.005f);
				nk_combo_end(ctx);
			}
		}
		nk_end(ctx);

		/* -------------- EXAMPLES ---------------- */
#ifdef INCLUDE_CALCULATOR
		calculator(ctx);
#endif
#ifdef INCLUDE_OVERVIEW
		overview(ctx);
#endif
#ifdef INCLUDE_NODE_EDITOR
		node_editor(ctx);
#endif
		/* ----------------------------------------- */
		/* ----------------------------------------- */
		RECT rect;
		GetClientRect(hwnd, &rect);
		int width = rect.right - rect.left;
		int height = rect.bottom - rect.top;

		// ウィンドウサイズの更新（これを追加）
		gl2.width = width;
		gl2.height = height;
		gl2.display_width = width;
		gl2.display_height = height;
		gl2.fb_scale = nk_vec2(1.0f, 1.0f);

		// 背景クリア
		glClearColor(bg.r, bg.g, bg.b, bg.a);
		glClear(GL_COLOR_BUFFER_BIT);

		// 2D描画用の設定
		glViewport(0, 0, width, height);
		glMatrixMode(GL_PROJECTION);
		glLoadIdentity();
		glOrtho(0.0f, (float)width, (float)height, 0.0f, -1.0f, 1.0f);
		glMatrixMode(GL_MODELVIEW);
		glLoadIdentity();

		// Nuklear GUIの描画準備
		glPushAttrib(GL_ENABLE_BIT | GL_COLOR_BUFFER_BIT | GL_TRANSFORM_BIT);

		// Nuklear GUIの描画
		nk_gl2_render(NK_ANTI_ALIASING_ON);

		// 状態を戻す
		glPopAttrib();

		// バッファの入れ替え
		SwapBuffers(hdc);
	}
	nk_gl2_shutdown();
	wglDeleteContext(hglrc);
	ReleaseDC(hwnd, hdc);
	DestroyWindow(hwnd);
	UnregisterClass(wc.lpszClassName, hInstance);
	return 0;
}
