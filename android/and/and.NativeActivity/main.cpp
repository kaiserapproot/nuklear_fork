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
        // ���������������Ă��Ȃ��ꍇ��A�f�B�X�v���C�����݂��Ȃ��ꍇ�͕`����s��Ȃ�
        if (!initializedDisplay || !display) return;

        // ���_�f�[�^���`
        const GLfloat vs[] = {
            0.0f, 0.5f, 0.0f,  // ���_1 (��)
            -0.5f, -0.5f, 0.0f, // ���_2 (����)
            0.5f, -0.5f, 0.0f  // ���_3 (�E��)
        };

        // ��ʂ��N���A����F��ݒ� (R, G, B, A)
        glClearColor(0.2, 0.5, 0.8, 1);
        // ��ʂ��N���A
        glClear(GL_COLOR_BUFFER_BIT);

        // �V�F�[�_�[�v���O�������g�p
        glUseProgram(hProg);

        // ���_�����|�C���^��ݒ�
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, vs);
        // ���_�����z���L����
        glEnableVertexAttribArray(0);

        // �O�p�`��`��
        glDrawArrays(GL_TRIANGLES, 0, 3);

        /* GUI BEGIN */
        // Nuklear�̃R���e�L�X�g���擾
        nk_context* ctx = &nk->ctx;

        // �E�B���h�E���J�n
        if (nk_begin(ctx, "Demo", nk_rect(50, 50, 200, 200),
            NK_WINDOW_BORDER | NK_WINDOW_MOVABLE | NK_WINDOW_SCALABLE |
            NK_WINDOW_CLOSABLE | NK_WINDOW_MINIMIZABLE | NK_WINDOW_TITLE))
        {
            // GUI�̃��C�A�E�g�ƃE�B�W�F�b�g��ݒ�
            enum { EASY, HARD };
            static int op = EASY;
            static int property = 20;

            // �{�^����z�u
            nk_layout_row_static(ctx, 30, 80, 1);
            if (nk_button_label(ctx, "button"))
                fprintf(stdout, "button pressed\n");

            // �I�v�V�����{�^����z�u
            nk_layout_row_dynamic(ctx, 30, 2);
            if (nk_option_label(ctx, "easy", op == EASY)) op = EASY;
            if (nk_option_label(ctx, "hard", op == HARD)) op = HARD;

            // �v���p�e�B��z�u
            nk_layout_row_dynamic(ctx, 22, 1);
            nk_property_int(ctx, "Compression:", 0, &property, 100, 10, 1);
        }
        // �E�B���h�E���I��
        nk_end(ctx);

        // Nuklear�̃����_�����O�����s
        nk->Render(NK_ANTI_ALIASING_ON);
        /* GUI END */

        // �o�b�t�@���X���b�v���ĉ�ʂɕ`��
        eglSwapBuffers(display, surface);
    }

    void TermDisplay()
    {
        // �f�B�X�v���C�����݂���ꍇ�̂ݏ������s��
        if (display != EGL_NO_DISPLAY)
        {
            // ���݂̃R���e�L�X�g�𖳌��ɂ���
            eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);

            // �R���e�L�X�g�����݂���ꍇ�͔j������
            if (context != EGL_NO_CONTEXT)
            {
                eglDestroyContext(display, context);
            }

            // �T�[�t�F�X�����݂���ꍇ�͔j������
            if (surface != EGL_NO_SURFACE)
            {
                eglDestroySurface(display, surface);
            }

            // �f�B�X�v���C���I������
            eglTerminate(display);
        }

        // �A�j���[�V�������~����
        animating = false;

        // �f�B�X�v���C�A�R���e�L�X�g�A�T�[�t�F�X�𖳌��ɂ���
        display = EGL_NO_DISPLAY;
        context = EGL_NO_CONTEXT;
        surface = EGL_NO_SURFACE;
    }
    static int InitDisplay(Engine* e)
    {
        // EGL�̐ݒ葮�����`
        const EGLint attribs[] = {
            EGL_SURFACE_TYPE, EGL_WINDOW_BIT, // �E�B���h�E�T�[�t�F�X���g�p
            EGL_BLUE_SIZE, 8,                 // �̃T�C�Y��8�r�b�g
            EGL_GREEN_SIZE, 8,                // �΂̃T�C�Y��8�r�b�g
            EGL_RED_SIZE, 8,                  // �Ԃ̃T�C�Y��8�r�b�g
            EGL_NONE                          // �I�[
        };

        // �f�B�X�v���C���擾
        EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
        // �f�B�X�v���C��������
        eglInitialize(display, 0, 0);
        // OpenGL ES API���o�C���h
        eglBindAPI(EGL_OPENGL_ES_API);

        // �g�p�\��EGL�t���[���o�b�t�@�\����I��
        // attribs�Ŏw�肵�������Ɉ�v����\�����擾
        EGLConfig config;
        EGLint numConfigs;
        eglChooseConfig(display, attribs, &config, 1, &numConfigs);
        if (numConfigs == 0)
        {
            LOGW("Unable to find a suitable EGLConfig");
            return -1;
        }

        // �l�C�e�B�u�E�B���h�E�̃o�b�t�@�t�H�[�}�b�g���擾
        // ����ɂ��AANativeWindow_setBuffersGeometry�Ŏg�p����t�H�[�}�b�g���擾
        EGLint format;
        eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &format);
        // �l�C�e�B�u�E�B���h�E�̃o�b�t�@�̃t�H�[�}�b�g��ݒ�
        // ����ɂ��A�E�B���h�E�̃o�b�t�@���K�؂ȃt�H�[�}�b�g�Őݒ肳���
        ANativeWindow_setBuffersGeometry(e->app->window, 0, 0, format);

        // �E�B���h�E�T�[�t�F�X���쐬
        EGLSurface surface = eglCreateWindowSurface(display, config, e->app->window, NULL);
        // �R���e�L�X�g�������`
        const EGLint contextAttribs[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
        // �R���e�L�X�g���쐬
        EGLContext context = eglCreateContext(display, config, NULL, contextAttribs);

        // �R���e�L�X�g�����݂̃X���b�h�Ƀo�C���h
        if (eglMakeCurrent(display, surface, surface, context) == EGL_FALSE)
        {
            LOGW("Unable to eglMakeCurrent");
            return -1;
        }

        // �T�[�t�F�X�̕��ƍ������擾
        EGLint w, h;
        eglQuerySurface(display, surface, EGL_WIDTH, &w);
        eglQuerySurface(display, surface, EGL_HEIGHT, &h);

        // �G���W���̃f�B�X�v���C�A�R���e�L�X�g�A�T�[�t�F�X�A���A������ݒ�
        e->display = display;
        e->context = context;
        e->surface = surface;
        e->width = w;
        e->height = h;

        // �`��̃q���g��ݒ�
        glHint(GL_PERSPECTIVE_CORRECTION_HINT, GL_FASTEST);
        // �r���[�|�[�g��ݒ�
        glViewport(0, 0, w, h);
        // �V�F�[�_�[�v���O�������쐬
        e->hProg = generate_shader_program(vShader, fShader);
        // Nuklear�̏�����
        e->nk = new NkGLES(e->display, e->surface, MAX_VERTEX_MEMORY, MAX_ELEMENT_MEMORY); // NK
        // �������������������Ƃ�ݒ�
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

    // �r���[�|�[�g��ݒ�
    glViewport(0, 0, width, height);
    // ��ʂ��N���A����F��ݒ� (R, G, B, A)
    glClearColor(0.2f, 0.2f, 0.2f, 0.0f);

    // ���_�V�F�[�_�[�����[�h���ăR���p�C��
    engine->vertexShader = loadShader(GL_VERTEX_SHADER, vertexShaderSource);
    // �t���O�����g�V�F�[�_�[�����[�h���ăR���p�C��
    engine->fragmentShader = loadShader(GL_FRAGMENT_SHADER, fragmentShaderSource);

    // �V�F�[�_�[�̃R���p�C���Ɏ��s�����ꍇ��0��Ԃ�
    if (!engine->vertexShader || !engine->fragmentShader)
    {
        return 0;
    }

    // �V�F�[�_�[�v���O�������쐬
    engine->program = glCreateProgram();
    // ���_�V�F�[�_�[���v���O�����ɃA�^�b�`
    glAttachShader(engine->program, engine->vertexShader);
    // �t���O�����g�V�F�[�_�[���v���O�����ɃA�^�b�`
    glAttachShader(engine->program, engine->fragmentShader);

    // ���_�����̈ʒu���o�C���h
    glBindAttribLocation(engine->program, 0, "position");

    // �V�F�[�_�[�v���O�����������N
    glLinkProgram(engine->program);
    // �����N�̃X�e�[�^�X���擾
    glGetProgramiv(engine->program, GL_LINK_STATUS, &linked);

    // �����N�Ɏ��s�����ꍇ�̓G���[���O���o�͂���0��Ԃ�
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

    // �V�F�[�_�[�v���O�������g�p
    glUseProgram(engine->program);

    // ���_�����̈ʒu���擾
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
    // �V�F�[�_�[�܂��̓v���O�����̃R���p�C��/�����N�X�e�[�^�X���擾
    switch (status)
    {
    case GL_COMPILE_STATUS:
        // �V�F�[�_�[�̃R���p�C���X�e�[�^�X���擾
        glGetShaderiv(o, status, &compiled);
        break;
    case GL_LINK_STATUS:
        // �v���O�����̃����N�X�e�[�^�X���擾
        glGetProgramiv(o, status, &compiled);
        break;
    }

    // �R���p�C���܂��̓����N�Ɏ��s�����ꍇ
    if (!compiled)
    {
        int len;
        // �G���[���O�̒������擾
        glGetShaderiv(o, GL_INFO_LOG_LENGTH, &len);
        // �G���[���O���i�[���邽�߂̃o�b�t�@���m��
        std::vector<char> errors(len + 1);
        // �G���[���O���擾
        glGetShaderInfoLog(o, len, 0, &errors[0]);
        // �G���[���O���o��
        LOGI("Error: %s\n", &errors[0]);
        // �R���p�C���܂��̓����N�Ɏ��s�������Ƃ������A�T�[�g
        assert(0);
    }
}

// �V�F�[�_�[�v���O�������쐬����֐�
// ���_�V�F�[�_�[�ƃt���O�����g�V�F�[�_�[�̃\�[�X�R�[�h���󂯎��A
// �������R���p�C�����ă����N���A�V�F�[�_�[�v���O�������쐬���܂��B
GLuint generate_shader_program(const char* pvShader, const char* pfShader)
{
    // ���_�V�F�[�_�[���쐬
    GLuint hVShader = glCreateShader(GL_VERTEX_SHADER);
    // �t���O�����g�V�F�[�_�[���쐬
    GLuint hFShader = glCreateShader(GL_FRAGMENT_SHADER);

    // ���_�V�F�[�_�[�̃\�[�X�R�[�h��ݒ�
    glShaderSource(hVShader, 1, &pvShader, 0);
    // �t���O�����g�V�F�[�_�[�̃\�[�X�R�[�h��ݒ�
    glShaderSource(hFShader, 1, &pfShader, 0);

    // ���_�V�F�[�_�[���R���p�C��
    glCompileShader(hVShader);
    // �t���O�����g�V�F�[�_�[���R���p�C��
    glCompileShader(hFShader);

    // ���_�V�F�[�_�[�̃R���p�C�����ʂ��`�F�b�N
    CheckCompiled(hVShader, GL_COMPILE_STATUS);
    // �t���O�����g�V�F�[�_�[�̃R���p�C�����ʂ��`�F�b�N
    CheckCompiled(hFShader, GL_COMPILE_STATUS);

    // �V�F�[�_�[�v���O�������쐬
    GLuint hProg = glCreateProgram();
    // ���_�V�F�[�_�[���v���O�����ɃA�^�b�`
    glAttachShader(hProg, hVShader);
    // �t���O�����g�V�F�[�_�[���v���O�����ɃA�^�b�`
    glAttachShader(hProg, hFShader);

    // ���_�����̈ʒu���o�C���h
    glBindAttribLocation(hProg, 0, "vPosition");

    // �V�F�[�_�[�v���O�����������N
    glLinkProgram(hProg);

    // �V�F�[�_�[�v���O�����̃����N���ʂ��`�F�b�N
    CheckCompiled(hProg, GL_LINK_STATUS);

    // �쐬�����V�F�[�_�[�v���O������Ԃ�
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
