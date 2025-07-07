#include <android/log.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <stdlib.h>
#include <string.h>

#define LOGI(...) ((void)__android_log_print(ANDROID_LOG_INFO, "NativeActivity", __VA_ARGS__))
#define LOGW(...) ((void)__android_log_print(ANDROID_LOG_WARN, "NativeActivity", __VA_ARGS__))

struct saved_state
{
    float angle;
    int32_t x;
    int32_t y;
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
    GLuint vs;
    GLuint fs;
    GLint mvp_location;
};

static const char* vertexShaderSource =
"attribute vec4 vertex;\n"
"uniform mat4 mvp_matrix;\n"
"void main() {\n"
"    gl_Position = mvp_matrix * vertex;\n"
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

    glViewport(0, 0, width, height);
    glClearColor(0.2f, 0.2f, 0.2f, 0.0f);

    engine->vs = loadShader(GL_VERTEX_SHADER, vertexShaderSource);
    engine->fs = loadShader(GL_FRAGMENT_SHADER, fragmentShaderSource);

    if (!engine->vs || !engine->fs)
    {
        return 0;
    }

    engine->program = glCreateProgram();
    glAttachShader(engine->program, engine->vs);
    glAttachShader(engine->program, engine->fs);

    glBindAttribLocation(engine->program, 0, "vertex");

    glLinkProgram(engine->program);
    glGetProgramiv(engine->program, GL_LINK_STATUS, &linked);

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

    glUseProgram(engine->program);

    engine->mvp_location = glGetUniformLocation(engine->program, "mvp_matrix");

    return 1;
}

void DrawTriangle()
{
    static const GLfloat vertices[] = {
        0.0f,  0.5f, 0.0f,
       -0.5f, -0.5f, 0.0f,
        0.5f, -0.5f, 0.0f,
    };

    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, vertices);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glDisableVertexAttribArray(0);
}

void DrawScene(struct engine* engine)
{
    glClear(GL_COLOR_BUFFER_BIT);

    float mvp[16] = {
        1.0f, 0.0f, 0.0f, 0.0f,
        0.0f, 1.0f, 0.0f, 0.0f,
        0.0f, 0.0f, 1.0f, 0.0f,
        0.0f, 0.0f, 0.0f, 1.0f,
    };

    glUniformMatrix4fv(engine->mvp_location, 1, GL_FALSE, mvp);

    DrawTriangle();

    eglSwapBuffers(engine->display, engine->surface);
}

static int engine_init_display(struct engine* engine)
{
    const EGLint attribs[] = {
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
    context = eglCreateContext(display, config, NULL, NULL);

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
    struct engine engine;

    memset(&engine, 0, sizeof(engine));
    state->userData = &engine;
    state->onAppCmd = engine_handle_cmd;
    state->onInputEvent = engine_handle_input;
    engine.app = state;

    engine.sensorManager = ASensorManager_getInstance();
    engine.accelerometerSensor = ASensorManager_getDefaultSensor(engine.sensorManager,
        ASENSOR_TYPE_ACCELEROMETER);
    engine.sensorEventQueue = ASensorManager_createEventQueue(engine.sensorManager,
        state->looper, LOOPER_ID_USER, NULL, NULL);

    if (state->savedState != NULL)
    {
        engine.state = *(struct saved_state*)state->savedState;
    }

    engine.animating = 1;

    while (1)
    {
        int ident;
        int events;
        struct android_poll_source* source;

        while ((ident = ALooper_pollAll(engine.animating ? 0 : -1, NULL, &events,
            (void**)&source)) >= 0)
        {

            if (source != NULL)
            {
                source->process(state, source);
            }

            if (ident == LOOPER_ID_USER)
            {
                if (engine.accelerometerSensor != NULL)
                {
                    ASensorEvent event;
                    while (ASensorEventQueue_getEvents(engine.sensorEventQueue,
                        &event, 1) > 0)
                    {
                        LOGI("accelerometer: x=%f y=%f z=%f",
                            event.acceleration.x, event.acceleration.y,
                            event.acceleration.z);
                    }
                }
            }

            if (state->destroyRequested != 0)
            {
                engine_term_display(&engine);
                return;
            }
        }

        if (engine.animating)
        {
            engine.state.angle += .01f;
            if (engine.state.angle > 1)
            {
                engine.state.angle = 0;
            }

            engine_draw_frame(&engine);
        }
    }
}
