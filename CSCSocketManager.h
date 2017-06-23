//
//  CSCSocketManager.h
//  cn.cloudScreen
//
//  Created by 丁祎 on 2017/3/29.
//  Copyright © 2017年 云屏科技. All rights reserved.
//

#import <Foundation/Foundation.h>

@class HomeModel;

@interface CSCSocketManager : NSObject

@property (nonatomic, strong) HomeModel *homeModel;

+(instancetype)sharedInstance;

-(BOOL)startListen:(HomeModel *)homeModel;

- (void) stopListen;

@end
