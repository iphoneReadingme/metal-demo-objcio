//
//  METLViewController.m
//  MetalDemo
//
//  Created by Warren Moore on 10/28/14.
//  Copyright (c) 2014 objc.io. All rights reserved.
//

#import "METLViewController.h"

@import Metal;
@import simd;
@import QuartzCore.CAMetalLayer;

static matrix_float4x4 rotation_matrix_2d(float radians)
{
    float cos = cosf(radians);
    float sin = sinf(radians);
    
    matrix_float4x4 m = {
        .columns[0] = {  cos, sin, 0, 0 },
        .columns[1] = { -sin, cos, 0, 0 },
        .columns[2] = {    0,   0, 1, 0 },
        .columns[3] = {    0,   0, 0, 1 }
    };
    return m;
}

///< 每一行的前四个数字代表了每一个顶点的 x，y，z 和 w 元素。后四个数字代表每个顶点的红色，绿色，蓝色和透明值元素。
static float quadVertexData[] =
{
     0.5, -0.5, 0.0, 1.0,     1.0, 0.0, 0.0, 1.0,
    -0.5, -0.5, 0.0, 1.0,     0.0, 1.0, 0.0, 1.0,
    -0.5,  0.5, 0.0, 1.0,     0.0, 0.0, 1.0, 1.0,
    
     0.5,  0.5, 0.0, 1.0,     1.0, 1.0, 0.0, 1.0,
     0.5, -0.5, 0.0, 1.0,     1.0, 0.0, 0.0, 1.0,
    -0.5,  0.5, 0.0, 1.0,     0.0, 0.0, 1.0, 1.0,
};

typedef struct
{
    matrix_float4x4 rotation_matrix;
} Uniforms;

@interface METLViewController ()

// Long-lived Metal objects
@property (nonatomic, strong) CAMetalLayer *metalLayer;
@property (nonatomic, strong) id<MTLDevice> device;
@property (nonatomic, strong) id<MTLCommandQueue> commandQueue;
@property (nonatomic, strong) id<MTLLibrary> defaultLibrary;
@property (nonatomic, strong) id<MTLRenderPipelineState> pipelineState;

// Resources
@property (nonatomic, strong) id<MTLBuffer> uniformBuffer;
@property (nonatomic, strong) id<MTLBuffer> vertexBuffer;

// Transient objects
@property (nonatomic, strong) id<CAMetalDrawable> currentDrawable;

@property (nonatomic, strong) CADisplayLink *timer;

@property (nonatomic, assign) BOOL layerSizeDidUpdate;
@property (nonatomic, assign) Uniforms uniforms;
@property (nonatomic, assign) float rotationAngle;

@end

@implementation METLViewController

- (void)dealloc {
    [_timer invalidate];
}

- (void)viewDidLoad {
    [super viewDidLoad];

    [self setupMetal];
    [self buildPipeline];
    
    // Set up the render loop to redraw in sync with the main screen refresh rate
    self.timer = [CADisplayLink displayLinkWithTarget:self selector:@selector(redraw)];
    [self.timer addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
}

- (BOOL)prefersStatusBarHidden {
    return YES;
}

- (void)setupMetal {
	// Create the default Metal device, 使用MTLCreateSystemDefaultDevice 函数来获取默认设备: 注意 device 并不是一个详细具体的类，正如前面提到的，它是遵循 MTLDevice 协议的类。
    self.device = MTLCreateSystemDefaultDevice();
	
	///< 下面的代码展示了如何创建一个 Metal layer 并将它作为 sublayer 添加到一个 UIView 的 layer:
	/*
	 CAMetalLayer 是 CALayer 的子类，它可以展示 Metal 帧缓冲区的内容。我们必须告诉 layer 该使用哪个 Metal 设备 (我们刚创建的那个)，并通知它所预期的像素格式。我们选择 8-bit-per-channel BGRA 格式，即每个像素由蓝，绿，红和透明组成，值从 0-255。
	 */
    // Create, configure, and add a Metal sublayer to the current layer
    self.metalLayer = [CAMetalLayer layer];
    self.metalLayer.device = self.device;
    self.metalLayer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    self.metalLayer.frame = self.view.bounds;
    [self.view.layer addSublayer:self.metalLayer];

	/*
	 命令队列
	 
	 命令通过与 Metal 设备相关联的命令队列提交给 Metal 设备。命令队列以线程安全的方式接收命令并顺序执行。创建一个命令队列:
	 */
    // Create a long-lived command queue
    self.commandQueue = [self.device newCommandQueue];
    
	///< 一个 Metal 库是一组函数的集合。你的所有写在工程内的着色器函数都将被编译到默认库中，这个库可以通过设备获得:
	// Get the library that contains the functions compiled into our app bundle
    self.defaultLibrary = [self.device newDefaultLibrary];

    self.view.contentScaleFactor = [UIScreen mainScreen].scale;
}

- (void)buildPipeline {
	///< 为了使用 Metal 绘制顶点数据，我们需要将它放入缓冲区。缓冲区是被 CPU 和 GPU 共享的简单的无结构的内存块:
    // Generate a vertex buffer for holding the vertex data of the quad
    self.vertexBuffer = [self.device newBufferWithBytes:quadVertexData
                                                 length:sizeof(quadVertexData)
                                                options:MTLResourceOptionCPUCacheModeDefault];

    // Generate a buffer for holding the uniform rotation matrix
    self.uniformBuffer = [self.device newBufferWithLength:sizeof(Uniforms) options:MTLResourceOptionCPUCacheModeDefault];

	/*
	 构建管道
	 
	 当我们在 Metal 编程中提到管道，指的是顶点数据在渲染时经历的变化。顶点着色器和片段着色器是管道中两个可编程的节点，但还有其它一定会发生的事件 (剪切，栅格化和视图变化) 不在我们的直接控制之下。管道特性中的后者的类组成了固定功能管道。
	 
	 在 Metal 中创建一个管道，我们需要指定对于每个顶点和每个像素分别想要执行哪个顶点和片段函数 (译者注: 片段着色器又被称为像素着色器)。我们还需要将帧缓冲区的像素格式告诉管道。在本例中，该格式必须与 Metal layer 的格式匹配，因为我们想在屏幕上绘制。
	 */
    // Fetch the vertex and fragment functions from the library
    id<MTLFunction> vertexProgram = [self.defaultLibrary newFunctionWithName:@"vertex_function"];      ///< 顶点着色器
    id<MTLFunction> fragmentProgram = [self.defaultLibrary newFunctionWithName:@"fragment_function"];  ///< 片段着色器又被称为像素着色器

	///< 接下来创建一个设置了函数和像素格式的管道描述器:
    // Build a render pipeline descriptor with the desired functions
    MTLRenderPipelineDescriptor *pipelineStateDescriptor = [[MTLRenderPipelineDescriptor alloc] init];
    [pipelineStateDescriptor setVertexFunction:vertexProgram];
    [pipelineStateDescriptor setFragmentFunction:fragmentProgram];
    pipelineStateDescriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
    
    // Compile the render pipeline
    NSError* error = NULL;
    self.pipelineState = [self.device newRenderPipelineStateWithDescriptor:pipelineStateDescriptor error:&error];
    if (!self.pipelineState) {
        NSLog(@"Failed to created pipeline state, error %@", error);
    }
}

- (MTLRenderPassDescriptor *)renderPassDescriptorForTexture:(id<MTLTexture>) texture
{
    // Configure a render pass with properties applicable to its single color attachment (i.e., the framebuffer)
    MTLRenderPassDescriptor *renderPassDescriptor = [MTLRenderPassDescriptor renderPassDescriptor];
    renderPassDescriptor.colorAttachments[0].texture = texture;
    renderPassDescriptor.colorAttachments[0].loadAction = MTLLoadActionClear;
    renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColorMake(1, 1, 1, 1);
    renderPassDescriptor.colorAttachments[0].storeAction = MTLStoreActionStore;
    return renderPassDescriptor;
}

- (void)render {
    [self update];
    
    id<MTLCommandBuffer> commandBuffer = [self.commandQueue commandBuffer];

	/*
	 准备绘制
	 
	 为了在 Metal layer 上绘制，首先我们需要从 layer 中获得一个 'drawable' 对象。这个可绘制对象管理着一组适合渲染的纹理:
	 */
    id<CAMetalDrawable> drawable = [self currentDrawable];

    // Set up a render pass to draw into the current drawable's texture
    MTLRenderPassDescriptor *renderPassDescriptor = [self renderPassDescriptorForTexture:drawable.texture];

    // Prepare a render command encoder with the current render pass
    id<MTLRenderCommandEncoder> renderEncoder = [commandBuffer renderCommandEncoderWithDescriptor:renderPassDescriptor];

    // Configure and issue our draw call
    [renderEncoder setRenderPipelineState:self.pipelineState];
    [renderEncoder setVertexBuffer:self.vertexBuffer offset:0 atIndex:0];
    [renderEncoder setVertexBuffer:self.uniformBuffer offset:0 atIndex:1];
    [renderEncoder drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:6];

    [renderEncoder endEncoding];

    // Request that the current drawable be presented when rendering is done
    [commandBuffer presentDrawable:drawable];
    
    // Finalize the command buffer and commit it to its queue
    [commandBuffer commit];
}

- (void)update {
    // Generate a rotation matrix for the current rotation angle
    _uniforms.rotation_matrix = rotation_matrix_2d(self.rotationAngle);

    // Copy the rotation matrix into the uniform buffer for the next frame
    void *bufferPointer = [self.uniformBuffer contents];
    memcpy(bufferPointer, &_uniforms, sizeof(Uniforms));
    
    // Update the rotation angle
    _rotationAngle += 0.01;
}

- (void)redraw {
    @autoreleasepool {
        if (self.layerSizeDidUpdate) {
            // Ensure that the drawable size of the Metal layer is equal to its dimensions in pixels
            CGFloat nativeScale = self.view.window.screen.nativeScale;
            CGSize drawableSize = self.metalLayer.bounds.size;
            drawableSize.width *= nativeScale;
            drawableSize.height *= nativeScale;
            self.metalLayer.drawableSize = drawableSize;

            self.layerSizeDidUpdate = NO;
        }
        
        // Draw the scene
        [self render];
        
        self.currentDrawable = nil;
    }
}

- (void)viewDidLayoutSubviews {
    self.layerSizeDidUpdate = YES;
    
    // Re-center the Metal layer in its containing layer with a 1:1 aspect ratio
    CGSize parentSize = self.view.bounds.size;
    CGFloat minSize = MIN(parentSize.width, parentSize.height);
    CGRect frame = CGRectMake((parentSize.width - minSize) / 2,
                              (parentSize.height - minSize) / 2,
                              minSize,
                              minSize);
    [self.metalLayer setFrame:frame];
}

- (id <CAMetalDrawable>)currentDrawable {
    // Our drawable may be nil if we're not on the screen or we've taken too long to render.
    // Block here until we can draw again.
    while (_currentDrawable == nil) {
        _currentDrawable = [self.metalLayer nextDrawable];
    }
    
    return _currentDrawable;
}

@end
