//Fix some annoying warnings
#define _CRT_SECURE_NO_DEPRECATE

//GLEW
#define GLEW_STATIC
#include <GL\glew.h>

//GLM
#include <glm/glm.hpp>
#include "glm/gtc/matrix_transform.hpp"

//GLFW
#include <GLFW\glfw3.h>

//CUDA
#include "cuda_runtime.h"
#include "device_launch_parameters.h"

//Project specific includes
#include <cuda_gl_interop.h>//Visualization
#include "cufftXt.h"		//CUDA FFT
#include "helper_cuda.h"	//heckCudaErrors

#include "RTDH_utility.h"	
#include "RTDH_GLFW.h"
#include "RTDH_CUDA.h"

__global__ void simple_vbo_kernel(float4 *pos, const int width, const int height);

__global__ void cufftComplex2Float(float *vbo_dptr, Complex *z, const int width, const int height);

void mainLoop(GLFWwindow* window, GLuint shaderprogram, GLuint projection_Handle, reconParameters parameters, cudaGraphicsResource *cuda_vbo_resource, Complex* d_recorded_hologram);

#define PI	3.1415926535897932384626433832795028841971693993751058209749
#define PI2 1.570796326794896619231321691639751442098584699687552910487

//TODO: -fix everything, reorganize headers so it makes sense
//		-perhaps generate a test hologram at a smaller size?
int main(){

	//=========================INITIALIZATION==========================
	//Redirect stderror to log.txt.
	FILE* logfile = freopen("log.txt", "w", stderr);
	printTime(logfile);

	//Read the reconstruction parameters. 
	reconParameters parameters;
	read_parameters("parameters.txt", &parameters);

	//Initialize the GLFW window
	GLFWwindow *window = initGLFW(parameters.N, parameters.M); 

	//Set a few callbacks
	glfwSetWindowSizeCallback(window, window_size_callback);
	glfwSetKeyCallback(window, key_callback);

	//Search for CUDA devices and pick the best-suited one. 
	findCUDAGLDevices();

	//Read the recorded hologram from a file. This will be replaced by the CCD later on.
	Complex* h_recorded_hologram = (Complex*)malloc(sizeof(Complex)*parameters.N*parameters.M);
	if (h_recorded_hologram == NULL){ printError(); exit(EXIT_FAILURE); }
	float* h_recorded_hologram_real = read_data("recorded_hologram_scaled.bin");

	for (int i = 0; i < parameters.M*parameters.N; i++){
		h_recorded_hologram[i].x =  h_recorded_hologram_real[i];
		h_recorded_hologram[i].y = 0.0;
	}
	
	//Copy the hologram to the GPU
	Complex* d_recorded_hologram;
	checkCudaErrors(cudaMalloc((void**)&d_recorded_hologram, sizeof(Complex)*parameters.N*parameters.M));

	checkCudaErrors(cudaMemcpy(d_recorded_hologram,h_recorded_hologram,sizeof(Complex)*parameters.N*parameters.M,cudaMemcpyHostToDevice));

	//We'll use a vertex array object with two VBO's. The first will house the vertex positions, the second will 
	//house the magnitude that will be calculated with a kernel. 
	
	GLuint vao;
	GLuint vbo[2];
	
	//Create the vertex array object and two vertex buffer object names.
	glGenVertexArrays(1, &vao);
	checkGLError(glGetError());
	
	glBindVertexArray(vao);
	checkGLError(glGetError());

	glGenBuffers(2, vbo);
	checkGLError(glGetError());

	//First let's set up all vertices in the first vbo. 
	glBindBuffer(GL_ARRAY_BUFFER, vbo[0]);
	checkGLError(glGetError());

	
	//Calculate the position of each vertex (one for every pixel in the image). 
	float u, v, x, y;
	int k = 0;

	
	float *vertices = (float *) malloc(parameters.N*parameters.M * 2 * sizeof(float));
	for (int i = 0; i < parameters.N; i++){
		for (int j = 0; j < parameters.M; j++){
			u = (float)i - 0.5f*(float)parameters.N;
			v = (float)j - 0.5f*(float)parameters.M;
			x = (u) / (0.5f*(float)parameters.N);
			y = (v) / (0.5f*(float)parameters.M);

			vertices[k] = x;
			vertices[k + 1] = y;
			k += 2;
		}
	}
	
	//Load these vertex coordinates into the first vbo
	glBufferData(GL_ARRAY_BUFFER, parameters.N*parameters.M * 2 * sizeof(GLfloat), vertices, GL_DYNAMIC_DRAW);
	checkGLError(glGetError());

	glVertexAttribPointer(0,2,GL_FLOAT,GL_FALSE,0,0);
	checkGLError(glGetError());

	glEnableVertexAttribArray(0);
	checkGLError(glGetError());

	//Bind the second VBO that will contain the magnitude of each complex number. 
	glBindBuffer(GL_ARRAY_BUFFER, vbo[1]);
	checkGLError(glGetError());

	glVertexAttribPointer(1, 1, GL_FLOAT, GL_FALSE, 0, 0);
	checkGLError(glGetError());

	glEnableVertexAttribArray(1);
	checkGLError(glGetError());

	//IDEE: schrijf een kernel van cufftcomplex - > VBO
	//This doesn't work, h_recorded_hologram is an array of structs with x- and y- fields, and glBufferData expects an array of the form 
	// x0 y0 | x1 y1 | ... | xn yn

	//This is the VBO that the complex magnitudes will be written to for visualization.
	glBufferData(GL_ARRAY_BUFFER, parameters.N*parameters.M * 1 * sizeof(GLfloat), 0, GL_DYNAMIC_DRAW);

	glBindBuffer(GL_ARRAY_BUFFER, 0);
	checkGLError(glGetError());

	cudaGraphicsResource *cuda_vbo_resource;
	checkCudaErrors(cudaGraphicsGLRegisterBuffer(&cuda_vbo_resource, vbo[1], cudaGraphicsMapFlagsWriteDiscard));

	//Compile vertex and fragment shaders

	GLuint shaderprogram = initShaders();
	checkGLError(glGetError());

	
	//=========================MAIN LOOP==========================

	//checkCudaErrors(cudaDeviceReset());

	GLuint projection_Handle= glGetUniformLocation(shaderprogram, "Projection");

	mainLoop(window, shaderprogram, projection_Handle, parameters, cuda_vbo_resource, d_recorded_hologram);
	
	glfwTerminate();

	free(vertices);
	free(h_recorded_hologram);
	checkCudaErrors(cudaFree(d_recorded_hologram));

	checkCudaErrors(cudaDeviceReset());

	fprintf(stderr, "No errors (that I'm aware of)! \n");
	fclose(logfile);

	return 0;
};

__global__ void cufftComplex2Float(float* vbo_magnitude, Complex *z, const int width, const int height){
	unsigned int i = blockIdx.x*blockDim.x + threadIdx.x;
	unsigned int j = blockIdx.y*blockDim.y + threadIdx.y;
	float magnitude = pow(z[j*height + i].x, (float)2) + pow(z[j*height + i].y, (float)2);
	vbo_magnitude[j*height + i] = (PI2 + atanf(sqrt(0.1*magnitude))) / PI;
};

//Why write it as a function anyway? Too much arguments !
void mainLoop(GLFWwindow* window, GLuint shaderprogram, GLuint projection_Handle, reconParameters parameters, cudaGraphicsResource *cuda_vbo_resource, Complex* d_recorded_hologram){
	// Measure frametime
	double frameTime = 0.0;
	int fps = 1;
	int fps_prev = 1;
	int framecounter = 1;
	std::string wtitle;

	while (!glfwWindowShouldClose(window))
	{
		glfwSetTime(0.0);
		float ratio = (float)parameters.N / (float)parameters.M;
		// handle events

		// map OpenGL buffer object for writing from CUDA

		float *dptr; //This will become a float2 as to be compatible with cuFFT
		checkCudaErrors(cudaGraphicsMapResources(1, &cuda_vbo_resource, 0));
		
		size_t num_bytes;
		checkCudaErrors(cudaGraphicsResourceGetMappedPointer((void **)&dptr, &num_bytes,
			cuda_vbo_resource));
		
		//Run kernel, this will become a simple kernel and cufftExecC2C call
		//First thing to do: get an external stream to 
		dim3 block(8, 8, 1);
		dim3 grid((unsigned int)parameters.N / block.x, (unsigned int)parameters.M / block.y, 1);
		cufftComplex2Float<<<grid, block >>>(dptr, d_recorded_hologram, parameters.N, parameters.M);
		checkCudaErrors(cudaGetLastError());
		
		// unmap buffer object
		checkCudaErrors(cudaGraphicsUnmapResources(1, &cuda_vbo_resource, 0));
		
		int w_width, w_height;
		glfwGetWindowSize(window, &w_width, &w_height);
		
		//glm::mat4 Projection = glm::ortho(-(float)parameters.N / (float)w_width, (float)parameters.N / (float)w_width, -(float)parameters.M / (float)w_height, (float)parameters.M / (float)w_height);
		glm::mat4 Projection = glm::ortho(-1.0,1.0,-1.0,1.0);

		glUniformMatrix4fv(projection_Handle, 1, GL_FALSE, &Projection[0][0]);


		glDrawArrays(GL_POINTS, 0, parameters.N*parameters.M);

		glfwSwapBuffers(window);
		glfwPollEvents();

		//Display fps in cmd, not sure if averaging is that useful
		frameTime = glfwGetTime();
		fps_prev = fps;
		fps = (int)(0.5*(1. / frameTime + (float)fps_prev));

		//Update FPS every 15 frames
		framecounter += 1;
		if (framecounter == 15){
			framecounter = 1;
			fprintf(stdout, "\r Frames Per Second: %i             ", fps);
			wtitle = std::to_string(fps);
			glfwSetWindowTitle(window, wtitle.c_str());
		}
	}
};