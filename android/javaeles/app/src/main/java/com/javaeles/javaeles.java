package com.javaeles;

import android.app.Activity;
import android.opengl.GLES30;
import android.opengl.GLSurfaceView;
import android.os.Bundle;
import android.widget.TextView;
import javax.microedition.khronos.egl.EGLConfig;
import javax.microedition.khronos.opengles.GL10;

public class javaeles extends Activity
{
    private GLSurfaceView glSurfaceView;

    /** アクティビティが最初に作成されるときに呼び出されます。 */
    @Override
    public void onCreate(Bundle savedInstanceState)
    {
        super.onCreate(savedInstanceState);

        glSurfaceView = new GLSurfaceView(this);
        glSurfaceView.setEGLContextClientVersion(3);
        glSurfaceView.setRenderer(new MyGLRenderer());
        setContentView(glSurfaceView);
    }

    private static class MyGLRenderer implements GLSurfaceView.Renderer
    {
        private int program;
        private int positionHandle;
        private int colorHandle;
        private final float[] vertices = {
            0.0f,  0.5f, 0.0f,
           -0.5f, -0.5f, 0.0f,
            0.5f, -0.5f, 0.0f
        };
        private final String vertexShaderCode =
            "#version 300 es\n" +
            "layout(location = 0) in vec4 vPosition;\n" +
            "void main() {\n" +
            "  gl_Position = vPosition;\n" +
            "}\n";
        private final String fragmentShaderCode =
            "#version 300 es\n" +
            "precision mediump float;\n" +
            "out vec4 fragColor;\n" +
            "void main() {\n" +
            "  fragColor = vec4(1.0, 0.0, 0.0, 1.0);\n" +
            "}\n";

        @Override
        public void onSurfaceCreated(GL10 gl, EGLConfig config)
        {
            GLES30.glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
            int vertexShader = loadShader(GLES30.GL_VERTEX_SHADER, vertexShaderCode);
            int fragmentShader = loadShader(GLES30.GL_FRAGMENT_SHADER, fragmentShaderCode);
            program = GLES30.glCreateProgram();
            GLES30.glAttachShader(program, vertexShader);
            GLES30.glAttachShader(program, fragmentShader);
            GLES30.glLinkProgram(program);
        }

        @Override
        public void onDrawFrame(GL10 gl)
        {
            GLES30.glClear(GLES30.GL_COLOR_BUFFER_BIT);
            GLES30.glUseProgram(program);
            positionHandle = GLES30.glGetAttribLocation(program, "vPosition");
            GLES30.glEnableVertexAttribArray(positionHandle);
            GLES30.glVertexAttribPointer(positionHandle, 3, GLES30.GL_FLOAT, false, 0, java.nio.ByteBuffer.allocateDirect(vertices.length * 4).order(java.nio.ByteOrder.nativeOrder()).asFloatBuffer().put(vertices).position(0));
            GLES30.glDrawArrays(GLES30.GL_TRIANGLES, 0, 3);
            GLES30.glDisableVertexAttribArray(positionHandle);
        }

        @Override
        public void onSurfaceChanged(GL10 gl, int width, int height)
        {
            GLES30.glViewport(0, 0, width, height);
        }

        private int loadShader(int type, String shaderCode)
        {
            int shader = GLES30.glCreateShader(type);
            GLES30.glShaderSource(shader, shaderCode);
            GLES30.glCompileShader(shader);
            return shader;
        }
    }
}
