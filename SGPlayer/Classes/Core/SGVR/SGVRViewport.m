//
//  SGVRViewport.m
//  SGPlayer
//
//  Created by Single on 2018/8/27.
//  Copyright © 2018 single. All rights reserved.
//

#import "SGVRViewport.h"

@implementation SGVRViewport

- (instancetype)init
{
    if (self = [super init]) {
        self.degress = 90;
        self.x = 0;
        self.y = 0;
        self.flipX = NO;
        self.flipY = NO;
        self.sensorEnable = YES;
    }
    return self;
}

@end
