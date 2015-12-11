/*
Copyright (C) 2015 Apple Inc. All Rights Reserved.
See LICENSE.txt for this sample’s licensing information

Abstract:
View controller for camera interface.
*/

#import <Foundation/NSObject.h>
#import <CoreLocation/CoreLocation.h>
#import "Chart/DSBarChart.h"
//#import "CorePlot-CocoaTouch.h"
@import UIKit;

@interface AAPLCameraViewController : UIViewController <UIPickerViewDataSource, UIPickerViewDelegate, CLLocationManagerDelegate, AVCaptureVideoDataOutputSampleBufferDelegate, NSURLConnectionDataDelegate>


@end
