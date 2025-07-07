#include <android/log.h>
#include <EGL/egl.h>
#include <GLES/gl.h>
//#include <GLES2/gl2.h>
//#include <GLES3/gl3.h>
#include <stdlib.h>
#include <string.h>
#include "NkGLES.h"
#include "overview.c"
#define LOGI(...) ((void)__android_log_print(ANDROID_LOG_INFO, "NativeActivity", __VA_ARGS__))
#define LOGW(...) ((void)__android_log_print(ANDROID_LOG_WARN, "NativeActivity", __VA_ARGS__))

struct saved_state
{
    float angle;
    int32_t x;
    int32_t y;
};
class Engine;
typedef struct android_app AndroidApp;
int initializedDisplay = false;
static int engine_init_display(Engine* eng);
GLuint generate_shader_program(const char* pvShader, const char* pfShader);
#include <jni.h>
#include <android/log.h>
#include <android/native_activity.h>

void WaitForDebugger(ANativeActivity* activity)
{
    JNIEnv* env;
    activity->vm->AttachCurrentThread(&env, NULL);

    jclass debugClass = env->FindClass("android/os/Debug");
    jmethodID waitForDebuggerMethod = env->GetStaticMethodID(debugClass, "waitForDebugger", "()V");
    env->CallStaticVoidMethod(debugClass, waitForDebuggerMethod);

    activity->vm->DetachCurrentThread();
}

const char* vShader =
"attribute vec4 vPosition;"
"void main() {"
" gl_Position = vPosition;"
"}";

const char* fShader =
"precision mediump float;"
"void main() {"
" gl_FragColor = vec4(1,0,1,1);"
"}";
class Engine
{
    AndroidApp* app;
    EGLDisplay display;
    EGLSurface surface;
    EGLContext context;
    int32_t width, height;
    GLuint hProg;
    NkGLES* nk; // NK
    bool initializedDisplay; // NK
public:
    bool animating;

    void DrawFrame()
    {
        // 初期化が完了していない場合や、ディスプレイが存在しない場合は描画を行わない
        if (!initializedDisplay || !display) return;

        // 頂点データを定義
        const GLfloat vs[] = {
            0.0f, 0.5f, 0.0f,  // 頂点1 (上)
            -0.5f, -0.5f, 0.0f, // 頂点2 (左下)
            0.5f, -0.5f, 0.0f  // 頂点3 (右下)
        };

        // 画面をクリアする色を設定 (R, G, B, A)
        glClearColor(0.2, 0.5, 0.8, 1);
        // 画面をクリア
        glClear(GL_COLOR_BUFFER_BIT);

        // シェーダープログラムを使用
        glUseProgram(hProg);

        // 頂点属性ポインタを設定
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, vs);
        // 頂点属性配列を有効化
        glEnableVertexAttribArray(0);

        // 三角形を描画
        glDrawArrays(GL_TRIANGLES, 0, 3);

        /* GUI BEGIN */
        // Nuklearのコンテキストを取得
        nk_context* ctx = &nk->ctx;

        // ウィンドウを開始
        if (nk_begin(ctx, "Demo", nk_rect(50, 50, 200, 200),
            NK_WINDOW_BORDER | NK_WINDOW_MOVABLE | NK_WINDOW_SCALABLE |
            NK_WINDOW_CLOSABLE | NK_WINDOW_MINIMIZABLE | NK_WINDOW_TITLE))
        {
            // GUIのレイアウトとウィジェットを設定
            enum { EASY, HARD };
            static int op = EASY;
            static int property = 20;

            // ボタンを配置
            nk_layout_row_static(ctx, 30, 80, 1);
            if (nk_button_label(ctx, "button"))
                fprintf(stdout, "button pressed\n");

            // オプションボタンを配置
            nk_layout_row_dynamic(ctx, 30, 2);
            if (nk_option_label(ctx, "easy", op == EASY)) op = EASY;
            if (nk_option_label(ctx, "hard", op == HARD)) op = HARD;

            // プロパティを配置
            nk_layout_row_dynamic(ctx, 22, 1);
            nk_property_int(ctx, "Compression:", 0, &property, 100, 10, 1);
        }
        // ウィンドウを終了
        nk_end(ctx);

        // Nuklearのレンダリングを実行
        nk->Render(NK_ANTI_ALIASING_ON);
        /* GUI END */

        // バッファをスワップして画面に描画
        eglSwapBuffers(display, surface);
    }

    void TermDisplay()
    {
        // ディスプレイが存在する場合のみ処理を行う
        if (display != EGL_NO_DISPLAY)
        {
            // 現在のコンテキストを無効にする
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

            // コンテキストが存在する場合は破棄する
            if (context != EGL_NO_CONTEXT)
            {
                eglDestroyContext(display, context);
            }

            // サーフェスが存在する場合は破棄する
            if (surface != EGL_NO_SURFACE)
            {
                eglDestroySurface(display, surface);
            }

            // ディスプレイを終了する
            eglTerminate(display);
        }

        // アニメーションを停止する
        animating = false;

        // ディスプレイ、コンテキスト、サーフェスを無効にする
        display = EGL_NO_DISPLAY;
        context = EGL_NO_CONTEXT;
        surface = EGL_NO_SURFACE;
    }
    static int InitDisplay(Engine* e)
    {
        // EGLの設定属性を定義
        const EGLint attribs[] = {
            EGL_SURFACE_TYPE, EGL_WINDOW_BIT, // ウィンドウサーフェスを使用
            EGL_BLUE_SIZE, 8,                 // 青のサイズを8ビット
            EGL_GREEN_SIZE, 8,                // 緑のサイズを8ビット
            EGL_RED_SIZE, 8,                  // 赤のサイズを8ビット
            EGL_NONE                          // 終端
        };

        // ディスプレイを取得
        EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        // ディスプレイを初期化
        eglInitialize(display, 0, 0);
        // OpenGL ES APIをバインド
        eglBindAPI(EGL_OPENGL_ES_API);

        // 使用可能なEGLフレームバッファ構成を選択
        // attribsで指定した属性に一致する構成を取得
        EGLConfig config;
        EGLint numConfigs;
        eglChooseConfig(display, attribs, &config, 1, &numConfigs);
        if (numConfigs == 0)
        {
            LOGW("Unable to find a suitable EGLConfig");
            return -1;
        }

        // ネイティブウィンドウのバッファフォーマットを取得
        // これにより、ANativeWindow_setBuffersGeometryで使用するフォーマットを取得
        EGLint format;
        eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &format);
        // ネイティブウィンドウのバッファのフォーマットを設定
        // これにより、ウィンドウのバッファが適切なフォーマットで設定される
        ANativeWindow_setBuffersGeometry(e->app->window, 0, 0, format);

        // ウィンドウサーフェスを作成
        EGLSurface surface = eglCreateWindowSurface(display, config, e->app->window, NULL);
        // コンテキスト属性を定義
        const EGLint contextAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        // コンテキストを作成
        EGLContext context = eglCreateContext(display, config, NULL, contextAttribs);

        // コンテキストを現在のスレッドにバインド
        if (eglMakeCurrent(display, surface, surface, context) == EGL_FALSE)
        {
            LOGW("Unable to eglMakeCurrent");
            return -1;
        }

        // サーフェスの幅と高さを取得
        EGLint w, h;
        eglQuerySurface(display, surface, EGL_WIDTH, &w);
        eglQuerySurface(display, surface, EGL_HEIGHT, &h);

        // エンジンのディスプレイ、コンテキスト、サーフェス、幅、高さを設定
        e->display = display;
        e->context = context;
        e->surface = surface;
        e->width = w;
        e->height = h;

        // 描画のヒントを設定
        glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_FASTEST);
        // ビューポートを設定
        glViewport(0, 0, w, h);
        // シェーダープログラムを作成
        e->hProg = generate_shader_program(vShader, fShader);
        // Nuklearの初期化
        e->nk = new NkGLES(e->display, e->surface, MAX_VERTEX_MEMORY, MAX_ELEMENT_MEMORY); // NK
        // 初期化が完了したことを設定
        e->initializedDisplay = true; // NK

        return 0;
    }


    static void HandleCmd(AndroidApp* app, int32_t cmd)
    {
        Engine* e = (Engine*)app->userData;
        switch (cmd)
        {
        case APP_CMD_INIT_WINDOW:
            if (e->app->window)
            {
                InitDisplay(e);
                e->DrawFrame();
            } break;
        case APP_CMD_TERM_WINDOW:
            e->TermDisplay();
            break;
        case APP_CMD_GAINED_FOCUS:
            break;
        case APP_CMD_LOST_FOCUS:
            //e->animating = false;
            e->DrawFrame();
            break;
        }
    }

    static int32_t HandleInput(AndroidApp* app, AInputEvent* e)
    { // NK
        Engine* eng = (Engine*)app->userData;
        switch (AInputEvent_getType(e))
        {
        case AINPUT_EVENT_TYPE_MOTION: { // Touch event
            float x = AMotionEvent_getX(e, 0);
            float y = AMotionEvent_getY(e, 0);
            nk_context* ctx = &eng->nk->ctx;
            nk_input_begin(ctx);
            switch (AMotionEvent_getAction(e) & AMOTION_EVENT_ACTION_MASK)
            {
            case AMOTION_EVENT_ACTION_DOWN: // WM_LBUTTONDOWN
                ctx->input.mouse.pos = nk_vec2(x, y);
                nk_input_button(ctx, NK_BUTTON_LEFT, x, y, true);
                break;
            case AMOTION_EVENT_ACTION_UP: // WM_LBUTTONUP
                ctx->input.mouse.pos = nk_vec2(0, 0);
                nk_input_button(ctx, NK_BUTTON_LEFT, x, y, false);
                break;
            case AMOTION_EVENT_ACTION_MOVE: // WM_MOUSEMOVE
                nk_input_motion(ctx, x, y);
                break;
            }
            nk_input_end(ctx);
        } return 1;
        case AINPUT_EVENT_TYPE_KEY:
            break;
        }
        return 0;
    }

    Engine(AndroidApp* state_)
    {
        memset(this, 0, sizeof(*this));
        state_->userData = this;
        state_->onAppCmd = Engine::HandleCmd;
        state_->onInputEvent = Engine::HandleInput; // NK
        app = state_;
        animating = true;
    }
    ~Engine() { delete nk; } // NK
};
struct engine
{
    struct android_app* app;

    ASensorManager* sensorManager;
    const ASensor* accelerometerSensor;
    ASensorEventQueue* sensorEventQueue;

    int animating;
    EGLDisplay display;
    EGLSurface surface;
    EGLContext context;
    int32_t width;
    int32_t height;
    struct saved_state state;

    GLuint program;
    GLuint vertexShader;
    GLuint fragmentShader;
    GLint positionLocation;
};

static const char* vertexShaderSource =
"attribute vec4 position;\n"
"void main() {\n"
"    gl_Position = position;\n"
"}\n";

static const char* fragmentShaderSource =
"precision mediump float;\n"
"void main() {\n"
"    gl_FragColor = vec4(1.0, 0.0, 0.0, 1.0);\n"
"}\n";

static GLuint loadShader(GLenum shaderType, const char* shaderSrc)
{
    GLuint shader = glCreateShader(shaderType);
    if (shader)
    {
        glShaderSource(shader, 1, &shaderSrc, NULL);
        glCompileShader(shader);
        GLint compiled;
        glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
        if (!compiled)
        {
            GLint len;
            glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &len);
            char* log = (char*)malloc(len);
            glGetShaderInfoLog(shader, len, &len, log);
            LOGW("Shader compilation failed: %s", log);
            free(log);
            glDeleteShader(shader);
            shader = 0;
        }
    }
    return shader;
}

int Initialize(struct engine* engine, int width, int height)
{
    GLint linked;

    // ビューポートを設定
    glViewport(0, 0, width, height);
    // 画面をクリアする色を設定 (R, G, B, A)
    glClearColor(0.2f, 0.2f, 0.2f, 0.0f);

    // 頂点シェーダーをロードしてコンパイル
    engine->vertexShader = loadShader(GL_VERTEX_SHADER, vertexShaderSource);
    // フラグメントシェーダーをロードしてコンパイル
    engine->fragmentShader = loadShader(GL_FRAGMENT_SHADER, fragmentShaderSource);

    // シェーダーのコンパイルに失敗した場合は0を返す
    if (!engine->vertexShader || !engine->fragmentShader)
    {
        return 0;
    }

    // シェーダープログラムを作成
    engine->program = glCreateProgram();
    // 頂点シェーダーをプログラムにアタッチ
    glAttachShader(engine->program, engine->vertexShader);
    // フラグメントシェーダーをプログラムにアタッチ
    glAttachShader(engine->program, engine->fragmentShader);

    // 頂点属性の位置をバインド
    glBindAttribLocation(engine->program, 0, "position");

    // シェーダープログラムをリンク
    glLinkProgram(engine->program);
    // リンクのステータスを取得
    glGetProgramiv(engine->program, GL_LINK_STATUS, &linked);

    // リンクに失敗した場合はエラーログを出力して0を返す
    if (!linked)
    {
        GLint len;
        glGetProgramiv(engine->program, GL_INFO_LOG_LENGTH, &len);
        char* log = (char*)malloc(len);
        glGetProgramInfoLog(engine->program, len, &len, log);
        LOGW("Program linking failed: %s", log);
        free(log);
        return 0;
    }

    // シェーダープログラムを使用
    glUseProgram(engine->program);

    // 頂点属性の位置を取得
    engine->positionLocation = glGetAttribLocation(engine->program, "position");

    return 1;
}



void DrawTriangle(struct engine* engine)
{
    static const GLfloat vertices[] = {
        0.0f,  0.5f, 0.0f,
       -0.5f, -0.5f, 0.0f,
        0.5f, -0.5f, 0.0f,
    };

    glEnableVertexAttribArray(engine->positionLocation);
    glVertexAttribPointer(engine->positionLocation, 3, GL_FLOAT, GL_FALSE, 0, vertices);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glDisableVertexAttribArray(engine->positionLocation);
}

void DrawScene(struct engine* engine)
{
    glClear(GL_COLOR_BUFFER_BIT);

    DrawTriangle(engine);

    eglSwapBuffers(engine->display, engine->surface);
}
void CheckCompiled(GLuint o, int status)
{
    int compiled;
    // シェーダーまたはプログラムのコンパイル/リンクステータスを取得
    switch (status)
    {
    case GL_COMPILE_STATUS:
        // シェーダーのコンパイルステータスを取得
        glGetShaderiv(o, status, &compiled);
        break;
    case GL_LINK_STATUS:
        // プログラムのリンクステータスを取得
        glGetProgramiv(o, status, &compiled);
        break;
    }

    // コンパイルまたはリンクに失敗した場合
    if (!compiled)
    {
        int len;
        // エラーログの長さを取得
        glGetShaderiv(o, GL_INFO_LOG_LENGTH, &len);
        // エラーログを格納するためのバッファを確保
        std::vector<char> errors(len + 1);
        // エラーログを取得
        glGetShaderInfoLog(o, len, 0, &errors[0]);
        // エラーログを出力
        LOGI("Error: %s\n", &errors[0]);
        // コンパイルまたはリンクに失敗したことを示すアサート
        assert(0);
    }
}

// シェーダープログラムを作成する関数
// 頂点シェーダーとフラグメントシェーダーのソースコードを受け取り、
// それらをコンパイルしてリンクし、シェーダープログラムを作成します。
GLuint generate_shader_program(const char* pvShader, const char* pfShader)
{
    // 頂点シェーダーを作成
    GLuint hVShader = glCreateShader(GL_VERTEX_SHADER);
    // フラグメントシェーダーを作成
    GLuint hFShader = glCreateShader(GL_FRAGMENT_SHADER);

    // 頂点シェーダーのソースコードを設定
    glShaderSource(hVShader, 1, &pvShader, 0);
    // フラグメントシェーダーのソースコードを設定
    glShaderSource(hFShader, 1, &pfShader, 0);

    // 頂点シェーダーをコンパイル
    glCompileShader(hVShader);
    // フラグメントシェーダーをコンパイル
    glCompileShader(hFShader);

    // 頂点シェーダーのコンパイル結果をチェック
    CheckCompiled(hVShader, GL_COMPILE_STATUS);
    // フラグメントシェーダーのコンパイル結果をチェック
    CheckCompiled(hFShader, GL_COMPILE_STATUS);

    // シェーダープログラムを作成
    GLuint hProg = glCreateProgram();
    // 頂点シェーダーをプログラムにアタッチ
    glAttachShader(hProg, hVShader);
    // フラグメントシェーダーをプログラムにアタッチ
    glAttachShader(hProg, hFShader);

    // 頂点属性の位置をバインド
    glBindAttribLocation(hProg, 0, "vPosition");

    // シェーダープログラムをリンク
    glLinkProgram(hProg);

    // シェーダープログラムのリンク結果をチェック
    CheckCompiled(hProg, GL_LINK_STATUS);

    // 作成したシェーダープログラムを返す
    return hProg;
}


static int engine_init_display(struct engine* engine)
{
    const EGLint attribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_BLUE_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_RED_SIZE, 8,
        EGL_NONE
    };
    EGLint w, h, format;
    EGLint numConfigs;
    EGLConfig config;
    EGLSurface surface;
    EGLContext context;

    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);

    eglInitialize(display, 0, 0);

    eglChooseConfig(display, attribs, &config, 1, &numConfigs);

    eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &format);

    ANativeWindow_setBuffersGeometry(engine->app->window, 0, 0, format);

    surface = eglCreateWindowSurface(display, config, engine->app->window, NULL);

    const EGLint contextAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    context = eglCreateContext(display, config, NULL, contextAttribs);

    if (eglMakeCurrent(display, surface, surface, context) == EGL_FALSE)
    {
        LOGW("Unable to eglMakeCurrent");
        return -1;
    }

    eglQuerySurface(display, surface, EGL_WIDTH, &w);
    eglQuerySurface(display, surface, EGL_HEIGHT, &h);

    engine->display = display;
    engine->context = context;
    engine->surface = surface;
    engine->width = w;
    engine->height = h;
    engine->state.angle = 0;

    if (!Initialize(engine, w, h))
    {
        return -1;
    }

    return 0;
}

static void engine_draw_frame(struct engine* engine)
{
    if (engine->display == NULL)
    {
        return;
    }

    DrawScene(engine);
}

static void engine_term_display(struct engine* engine)
{
    if (engine->display != EGL_NO_DISPLAY)
    {
        eglMakeCurrent(engine->display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (engine->context != EGL_NO_CONTEXT)
        {
            eglDestroyContext(engine->display, engine->context);
        }
        if (engine->surface != EGL_NO_SURFACE)
        {
            eglDestroySurface(engine->display, engine->surface);
        }
        eglTerminate(engine->display);
    }
    engine->animating = 0;
    engine->display = EGL_NO_DISPLAY;
    engine->context = EGL_NO_CONTEXT;
    engine->surface = EGL_NO_SURFACE;
}

static int32_t engine_handle_input(struct android_app* app, AInputEvent* event)
{
    struct engine* engine = (struct engine*)app->userData;
    if (AInputEvent_getType(event) == AINPUT_EVENT_TYPE_MOTION)
    {
        engine->state.x = AMotionEvent_getX(event, 0);
        engine->state.y = AMotionEvent_getY(event, 0);
        return 1;
    }
    return 0;
}

static void engine_handle_cmd(struct android_app* app, int32_t cmd)
{
    struct engine* engine = (struct engine*)app->userData;
    switch (cmd)
    {
    case APP_CMD_SAVE_STATE:
        engine->app->savedState = malloc(sizeof(struct saved_state));
        *((struct saved_state*)engine->app->savedState) = engine->state;
        engine->app->savedStateSize = sizeof(struct saved_state);
        break;
    case APP_CMD_INIT_WINDOW:
        if (engine->app->window != NULL)
        {
            engine_init_display(engine);
            engine_draw_frame(engine);
        }
        break;
    case APP_CMD_TERM_WINDOW:
        engine_term_display(engine);
        break;
    case APP_CMD_GAINED_FOCUS:
        if (engine->accelerometerSensor != NULL)
        {
            ASensorEventQueue_enableSensor(engine->sensorEventQueue,
                engine->accelerometerSensor);
            ASensorEventQueue_setEventRate(engine->sensorEventQueue,
                engine->accelerometerSensor, (1000L / 60) * 1000);
        }
        break;
    case APP_CMD_LOST_FOCUS:
        if (engine->accelerometerSensor != NULL)
        {
            ASensorEventQueue_disableSensor(engine->sensorEventQueue,
                engine->accelerometerSensor);
        }
        engine->animating = 0;
        engine_draw_frame(engine);
        break;
    }
}

void android_main(struct android_app* state)
{


        Engine e(state);
        struct android_poll_source* s;
        int events;

        while (true)
        {
            while (ALooper_pollAll(e.animating ? 0 : -1, NULL, &events, (void**)&s) >= 0)
            {
                if (s) s->process(state, s);
                if (state->destroyRequested)
                {
                    e.TermDisplay();
                    return;
                }
            }

            if (e.animating) e.DrawFrame();
        }

}
