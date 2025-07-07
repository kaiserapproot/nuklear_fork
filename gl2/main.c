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
 /* ���̃��C�u�����łł��邱�Ƃ̊T�v��񋟂��邽�߂̃R�[�h��ł��B��������ɂ́A�ȉ��̒�`���R�����g�������Ă������� */
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
static struct nk_context* ctx;  // �O���[�o���ϐ��Ƃ��Ēǉ�
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
    // Nuklear�̃C�x���g�n���h�����Ăяo��
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
		fprintf(stderr, "�E�B���h�E�N���X�̓o�^�Ɏ��s���܂���: %lu\n", GetLastError());
		return -1;
	}

	hwnd = CreateWindowEx(0, wc.lpszClassName, "Demo",
		WS_OVERLAPPEDWINDOW | WS_VISIBLE,
		CW_USEDEFAULT, CW_USEDEFAULT,
		WINDOW_WIDTH, WINDOW_HEIGHT,
		NULL, NULL, hInstance, NULL);

	if (!hwnd)
	{
		fprintf(stderr, "�E�B���h�E�̍쐬�Ɏ��s���܂���: %lu\n", GetLastError());
		return -1;
	}

	hdc = GetDC(hwnd);
	if (!hdc)
	{
		fprintf(stderr, "�f�o�C�X�R���e�L�X�g�̎擾�Ɏ��s���܂���: %lu\n", GetLastError());
		return -1;
	}

	{
		int format;
		PIXELFORMATDESCRIPTOR pfd = {
			sizeof(PIXELFORMATDESCRIPTOR),    // �T�C�Y
			1,                                // �o�[�W����
			PFD_DRAW_TO_WINDOW |             // �E�B���h�E
			PFD_SUPPORT_OPENGL |             // OpenGL
			PFD_DOUBLEBUFFER,                // �_�u���o�b�t�@
			PFD_TYPE_RGBA,                   // RGBA �^�C�v
			32,                              // 24-bit �J���[�[�x
			0, 0, 0, 0, 0, 0,               // �J���[�r�b�g�𖳎�
			0,                              // �A���t�@�o�b�t�@�Ȃ�
			0,                              // �V�t�g�r�b�g�𖳎�
			0,                              // �A�L�������[�V�����o�b�t�@�Ȃ�
			0, 0, 0, 0,                     // �A�L�������[�V�����r�b�g�𖳎�
			24,                             // 16-bit Z-�o�b�t�@
			8,                              // �X�e���V���o�b�t�@
			0,                              // �⏕�o�b�t�@�Ȃ�
			PFD_MAIN_PLANE,                 // ���C�����C���[
			0,                              // �\��ς�
			0, 0, 0                         // ���C���[�}�X�N�𖳎�
		};

		format = ChoosePixelFormat(hdc, &pfd);
		if (format == 0)
		{
			fprintf(stderr, "�s�N�Z���t�H�[�}�b�g�̑I���Ɏ��s���܂���: %lu\n", GetLastError());
			return -1;
		}

		if (!SetPixelFormat(hdc, format, &pfd))
		{
			fprintf(stderr, "�s�N�Z���t�H�[�}�b�g�̐ݒ�Ɏ��s���܂���: %lu\n", GetLastError());
			return -1;
		}

		// OpenGL�G���[�̃`�F�b�N�iOpenGL�ł͂Ȃ�Win32 API�̃G���[���m�F�j
		UINT gle = GetLastError();
		if (gle != 0)
		{
			fprintf(stderr, "SetPixelFormat �̌Ăяo����ɃG���[���������܂���: %lu\n", gle);
			return -1;
		}

		hglrc = wglCreateContext(hdc);
		if (!hglrc)
		{
			fprintf(stderr, "OpenGL�R���e�L�X�g�̍쐬�Ɏ��s���܂���: %lu\n", GetLastError());
			return -1;
		}

		if (!wglMakeCurrent(hdc, hglrc))
		{
			fprintf(stderr, "OpenGL�R���e�L�X�g�̐ݒ�Ɏ��s���܂���: %lu\n", GetLastError());
			return -1;
		}
		check_gl_error("wglMakeCurrent", __FILE__, __LINE__);
		// OpenGL�����ݒ�
		glEnable(GL_BLEND);
		glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
		glClearColor(0.0f, 0.0f, 0.0f, 0.0f);
		glViewport(0, 0, WINDOW_WIDTH, WINDOW_HEIGHT);
		// OpenGL�����ݒ�iwglMakeCurrent��j
		GL_CHECK(glEnable(GL_BLEND));
		GL_CHECK(glEnable(GL_TEXTURE_2D));
		GL_CHECK(glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA));
		GL_CHECK(glEnable(GL_CULL_FACE));
		GL_CHECK(glCullFace(GL_BACK));
		GL_CHECK(glFrontFace(GL_CCW));  // �����v����\�����ɐݒ�
		// OpenGL�����ݒ�iwglMakeCurrent��j
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
		fprintf(stderr, "Nuklear�R���e�L�X�g�̏������Ɏ��s���܂���\n");
		return -1;
	}

	// gl2�\���̂̏�������ǉ�
	gl2.width = WINDOW_WIDTH;
	gl2.height = WINDOW_HEIGHT;
	gl2.display_width = WINDOW_WIDTH;
	gl2.display_height = WINDOW_HEIGHT;
	gl2.fb_scale = nk_vec2(1.0f, 1.0f);

	/* �t�H���g�̓ǂݍ��݁i�K�v�ɉ����āj */
	{
		struct nk_font_atlas* atlas;
		nk_gl2_font_stash_begin(&atlas);
		/* �t�H���g�̒ǉ��� */
		/* struct nk_font *droid = nk_font_atlas_add_from_file(atlas, "../../../extra_font/DroidSans.ttf", 14, 0); */
		nk_gl2_font_stash_end();
		/* nk_style_load_all_cursors(ctx, atlas->cursors); */
		/* nk_style_set_font(ctx, &droid->handle); */
	}

#ifdef INCLUDE_STYLE
	/* �e�[�}�̐ݒ�� */
	/* set_style(ctx, THEME_WHITE); */
	/* set_style(ctx, THEME_RED); */
	/* set_style(ctx, THEME_BLUE); */
	/* set_style(ctx, THEME_DARK); */
#endif

	/* �w�i�F�̏����� */
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

            // �}�E�X�̈ʒu���擾���čX�V
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

		// �E�B���h�E�T�C�Y�̍X�V�i�����ǉ��j
		gl2.width = width;
		gl2.height = height;
		gl2.display_width = width;
		gl2.display_height = height;
		gl2.fb_scale = nk_vec2(1.0f, 1.0f);

		// �w�i�N���A
		glClearColor(bg.r, bg.g, bg.b, bg.a);
		glClear(GL_COLOR_BUFFER_BIT);

		// 2D�`��p�̐ݒ�
		glViewport(0, 0, width, height);
		glMatrixMode(GL_PROJECTION);
		glLoadIdentity();
		glOrtho(0.0f, (float)width, (float)height, 0.0f, -1.0f, 1.0f);
		glMatrixMode(GL_MODELVIEW);
		glLoadIdentity();

		// Nuklear GUI�̕`�揀��
		glPushAttrib(GL_ENABLE_BIT | GL_COLOR_BUFFER_BIT | GL_TRANSFORM_BIT);

		// Nuklear GUI�̕`��
		nk_gl2_render(NK_ANTI_ALIASING_ON);

		// ��Ԃ�߂�
		glPopAttrib();

		// �o�b�t�@�̓���ւ�
		SwapBuffers(hdc);
	}
	nk_gl2_shutdown();
	wglDeleteContext(hglrc);
	ReleaseDC(hwnd, hdc);
	DestroyWindow(hwnd);
	UnregisterClass(wc.lpszClassName, hInstance);
	return 0;
}
