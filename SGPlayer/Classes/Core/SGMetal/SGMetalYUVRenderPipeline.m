//
//  SGMetalYUVRenderPipeline.m
//  MetalTest
//
//  Created by Single on 2019/6/26.
//  Copyright © 2019 Single. All rights reserved.
//

#import "SGMetalYUVRenderPipeline.h"

@implementation SGMetalYUVRenderPipeline

- (instancetype)initWithDevice:(id<MTLDevice>)device library:(id<MTLLibrary>)library
{
    if (self = [super initWithDevice:device library:library]) {
        self.descriptor = [[MTLRenderPipelineDescriptor alloc] init];
        self.descriptor.vertexFunction = [self.library newFunctionWithName:@"vertexShader"];
        self.descriptor.fragmentFunction = [self.library newFunctionWithName:@"fragmentShaderYUV"];
        self.descriptor.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm;
        NSError *error = nil;
        self.state = [self.device newRenderPipelineStateWithDescriptor:self.descriptor error:&error];
        if (!self.state) {
            NSLog(@"SGPlayer Metal pipeline failed: %@", error);
            return nil;
        }
    }
    return self;
}

@end


