/*
Copyright (C) 2015 Apple Inc. All Rights Reserved.
See LICENSE.txt for this sample’s licensing information

Abstract:
View controller for camera interface.
*/

@import AVFoundation;
@import Photos;

#import "AAPLCameraViewController.h"
#import "AAPLPreviewView.h"

static void * CapturingStillImageContext = &CapturingStillImageContext;
static void * SessionRunningContext = &SessionRunningContext;

static void * AdjustingFocusObservationContext = (void*)&AdjustingFocusObservationContext;
static void * AdjustingExposureObservationContext = (void*)&AdjustingExposureObservationContext;

typedef NS_ENUM( NSInteger, AVCamSetupResult ) {
	AVCamSetupResultSuccess,
	AVCamSetupResultCameraNotAuthorized,
	AVCamSetupResultSessionConfigurationFailed
};

enum AutoMode {None, AutoInc, AutoDec};

@interface AAPLCameraViewController ()

@property (weak, nonatomic) IBOutlet UIView *ChartView;

// For iBeacon data collection
// UI parts
@property (weak, nonatomic) IBOutlet UITextField *xTextField;

@property (weak, nonatomic) IBOutlet UITextField *yTextField;
//@property (weak, nonatomic) IBOutlet UIStepper *xStepper;
//@property (weak, nonatomic) IBOutlet UIStepper *yStepper;
@property (weak, nonatomic) IBOutlet UILabel *countDownLabel;
@property (weak, nonatomic) IBOutlet UILabel *estLabel;
@property (weak, nonatomic) IBOutlet UILabel *estBeaconLabel;
//@property (weak, nonatomic) IBOutlet UIPickerView *sampleNumPicker;
//@property (weak, nonatomic) IBOutlet UITextView *beaconFilterTextView;
//@property (weak, nonatomic) IBOutlet UITextField *edgeIDTextField;
//@property (weak, nonatomic) IBOutlet UISegmentedControl *xAutoModeSeg;
//@property (weak, nonatomic) IBOutlet UISegmentedControl *yAutoModeSeg;
@property (weak, nonatomic) IBOutlet UILabel *fpsLabel;
@property (weak, nonatomic) IBOutlet UISlider *fpsSlider;
@property (weak, nonatomic) IBOutlet UIButton *fixFocusExposureButton;
@property (strong, nonatomic) IBOutlet UIImageView *focusCursor;

@property (nonatomic) enum AutoMode xAutoMode;
@property (nonatomic) enum AutoMode yAutoMode;

// UI parts related var
@property (strong, nonatomic) NSArray *pickerStrs;
@property (strong, nonatomic) NSSet *beaconMinors;
@property (strong, nonatomic) NSString *beaconFilterString;


//@property (strong, nonatomic) NSString *imgFilePath;
@property (strong, nonatomic) NSMutableString *estPosition;
@property (strong, nonatomic) NSFileHandle *estPositionDataFile;

// iBeacon var
@property (strong, nonatomic) CLLocationManager *beaconManager;
@property (strong, nonatomic) CLBeaconRegion *beaconRegion;
@property (strong, nonatomic) NSUUID *uuid;
@property (nonatomic) bool isBeaconUpdated;

// Counter related var
@property (nonatomic) int currentSmpNum;
@property (nonatomic) int targetSmpNum;
@property (strong, nonatomic) NSTimer *timberImgseq;

// Camera
@property (nonatomic) Float64 exposeFPS;
@property (nonatomic) Float64 lensPosition;
@property (nonatomic) Float64 ISO;

// writing data to files
@property (strong, nonatomic) NSFileHandle *dataFile;
@property (nonatomic) Boolean isSampling;
@property (nonatomic) Boolean isRecording;
@property (nonatomic) Boolean isVideoing;
@property (nonatomic) NSString *videoFileName;


// For use in the storyboards.
@property (nonatomic, weak) IBOutlet AAPLPreviewView *previewView;
@property (nonatomic, weak) IBOutlet UILabel *cameraUnavailableLabel;
@property (nonatomic, weak) IBOutlet UIButton *resumeButton;
@property (nonatomic, weak) IBOutlet UIButton *recordButton;
@property (nonatomic, weak) IBOutlet UIButton *cameraButton;
@property (nonatomic, weak) IBOutlet UIButton *stillButton;
@property (weak, nonatomic) IBOutlet UIButton *videoButton;
@property (weak, nonatomic) IBOutlet UIButton *logButton;

@property (nonatomic) dispatch_queue_t imgSeqQueue;
// Session management.
@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (nonatomic) AVCaptureVideoDataOutput *videoImageOutput;
@property (nonatomic) AVCaptureMovieFileOutput *movieFileOutput;
@property (nonatomic) AVCaptureStillImageOutput *stillImageOutput;

// Utilities.
@property (nonatomic) AVCamSetupResult setupResult;
@property (nonatomic, getter=isSessionRunning) BOOL sessionRunning;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID;

@end

@implementation AAPLCameraViewController

- (void)viewDidLoad
{
	[super viewDidLoad];
    
    _isVideoing = NO;
    _isRecording = NO;
    
    self.isBeaconUpdated = false;
    self.imgSeqQueue = dispatch_queue_create( "img seq queue", DISPATCH_QUEUE_SERIAL );
    
    
	// Disable UI. The UI is enabled if and only if the session starts running.
	self.cameraButton.enabled = NO;
	self.recordButton.enabled = NO;
	self.stillButton.enabled = NO;
    self.videoButton.enabled = NO;

	// Create the AVCaptureSession.
	self.session = [[AVCaptureSession alloc] init];

	// Setup the preview view.
	self.previewView.session = self.session;

	// Communicate with the session and other session objects on this queue.
	self.sessionQueue = dispatch_queue_create( "session queue", DISPATCH_QUEUE_SERIAL );

	self.setupResult = AVCamSetupResultSuccess;

	// Check video authorization status. Video access is required and audio access is optional.
	// If audio access is denied, audio is not recorded during movie recording.
	switch ( [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] )
	{
		case AVAuthorizationStatusAuthorized:
		{
			// The user has previously granted access to the camera.
			break;
		}
		case AVAuthorizationStatusNotDetermined:
		{
			// The user has not yet been presented with the option to grant video access.
			// We suspend the session queue to delay session setup until the access request has completed to avoid
			// asking the user for audio access if video access is denied.
			// Note that audio access will be implicitly requested when we create an AVCaptureDeviceInput for audio during session setup.
			dispatch_suspend( self.sessionQueue );
			[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^( BOOL granted ) {
				if ( ! granted ) {
					self.setupResult = AVCamSetupResultCameraNotAuthorized;
				}
				dispatch_resume( self.sessionQueue );
			}];
			break;
		}
		default:
		{
			// The user has previously denied access.
			self.setupResult = AVCamSetupResultCameraNotAuthorized;
			break;
		}
	}

	// Setup the capture session.
	// In general it is not safe to mutate an AVCaptureSession or any of its inputs, outputs, or connections from multiple threads at the same time.
	// Why not do all of this on the main queue?
	// Because -[AVCaptureSession startRunning] is a blocking call which can take a long time. We dispatch session setup to the sessionQueue
	// so that the main queue isn't blocked, which keeps the UI responsive.
	dispatch_async( self.sessionQueue, ^{
		if ( self.setupResult != AVCamSetupResultSuccess ) {
			return;
		}

		self.backgroundRecordingID = UIBackgroundTaskInvalid;
		NSError *error = nil;

		AVCaptureDevice *videoDevice = [AAPLCameraViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:AVCaptureDevicePositionBack];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];

		if ( ! videoDeviceInput ) {
			NSLog( @"Could not create video device input: %@", error );
		}

		[self.session beginConfiguration];

		if ( [self.session canAddInput:videoDeviceInput] ) {
			[self.session addInput:videoDeviceInput];
			self.videoDeviceInput = videoDeviceInput;

			dispatch_async( dispatch_get_main_queue(), ^{
				// Why are we dispatching this to the main queue?
				// Because AVCaptureVideoPreviewLayer is the backing layer for AAPLPreviewView and UIView
				// can only be manipulated on the main thread.
				// Note: As an exception to the above rule, it is not necessary to serialize video orientation changes
				// on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.

				// Use the status bar orientation as the initial video orientation. Subsequent orientation changes are handled by
				// -[viewWillTransitionToSize:withTransitionCoordinator:].
				UIInterfaceOrientation statusBarOrientation = [UIApplication sharedApplication].statusBarOrientation;
				AVCaptureVideoOrientation initialVideoOrientation = AVCaptureVideoOrientationPortrait;
				if ( statusBarOrientation != UIInterfaceOrientationUnknown ) {
					initialVideoOrientation = (AVCaptureVideoOrientation)statusBarOrientation;
				}

				AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
				previewLayer.connection.videoOrientation = initialVideoOrientation;
			} );
		}
		else {
			NSLog( @"Could not add video device input to the session" );
			self.setupResult = AVCamSetupResultSessionConfigurationFailed;
		}

		AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
		AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];

		if ( ! audioDeviceInput ) {
			NSLog( @"Could not create audio device input: %@", error );
		}

		if ( [self.session canAddInput:audioDeviceInput] ) {
			[self.session addInput:audioDeviceInput];
		}
		else {
			NSLog( @"Could not add audio device input to the session" );
		}
        
        
        _videoFileName = [NSString stringWithFormat:@""];
        AVCaptureVideoDataOutput *videoImageOutput = [[AVCaptureVideoDataOutput alloc] init];
        if ( [self.session canAddOutput:videoImageOutput] ) {
            
            videoImageOutput.videoSettings = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCVPixelFormatType_32BGRA]
                                                                         forKey:(id)kCVPixelBufferPixelFormatTypeKey];
//            videoImageOutput.minFrameDuration = CMTimeMake(1, 30);
            [videoImageOutput setSampleBufferDelegate:self queue:self.sessionQueue];
            
            [[videoImageOutput connectionWithMediaType:AVMediaTypeVideo] setEnabled:YES];
            [self.session addOutput:videoImageOutput];
            self.videoImageOutput = videoImageOutput;
            
        } else {
            NSLog( @"Could not add image sequence output to the session" );
            self.setupResult = AVCamSetupResultSessionConfigurationFailed;
        }

		AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
		if ( [self.session canAddOutput:movieFileOutput] ) {
//			[self.session addOutput:movieFileOutput];
//            [self.session removeOutput:movieFileOutput];
			AVCaptureConnection *connection = [movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
			if ( connection.isVideoStabilizationSupported ) {
				connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
			}
			self.movieFileOutput = movieFileOutput;
		}
		else {
			NSLog( @"Could not add movie file output to the session" );
			self.setupResult = AVCamSetupResultSessionConfigurationFailed;
		}

		AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
		if ( [self.session canAddOutput:stillImageOutput] ) {
			stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
			[self.session addOutput:stillImageOutput];
			self.stillImageOutput = stillImageOutput;
		}
		else {
			NSLog( @"Could not add still image output to the session" );
			self.setupResult = AVCamSetupResultSessionConfigurationFailed;
		}

		[self.session commitConfiguration];
	} );
    
    [self initFocusCursor];
    
    [self initBeacon];
    
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];

	dispatch_async( self.sessionQueue, ^{
		switch ( self.setupResult )
		{
			case AVCamSetupResultSuccess:
			{
				// Only setup observers and start the session running if setup succeeded.
				[self addObservers];
				[self.session startRunning];
				self.sessionRunning = self.session.isRunning;
				break;
			}
			case AVCamSetupResultCameraNotAuthorized:
			{
				dispatch_async( dispatch_get_main_queue(), ^{
					NSString *message = NSLocalizedString( @"AVCam doesn't have permission to use the camera, please change privacy settings", @"Alert message when the user has denied access to the camera" );
					UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
					UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
					[alertController addAction:cancelAction];
					// Provide quick access to Settings.
					UIAlertAction *settingsAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"Settings", @"Alert button to open Settings" ) style:UIAlertActionStyleDefault handler:^( UIAlertAction *action ) {
						[[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
					}];
					[alertController addAction:settingsAction];
					[self presentViewController:alertController animated:YES completion:nil];
				} );
				break;
			}
			case AVCamSetupResultSessionConfigurationFailed:
			{
				dispatch_async( dispatch_get_main_queue(), ^{
					NSString *message = NSLocalizedString( @"Unable to capture media", @"Alert message when something goes wrong during capture session configuration" );
					UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
					UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
					[alertController addAction:cancelAction];
					[self presentViewController:alertController animated:YES completion:nil];
				} );
				break;
			}
		}
	} );
    
    [_beaconManager startRangingBeaconsInRegion:_beaconRegion];
}

- (void)viewDidDisappear:(BOOL)animated
{
	dispatch_async( self.sessionQueue, ^{
		if ( self.setupResult == AVCamSetupResultSuccess ) {
			[self.session stopRunning];
			[self removeObservers];
		}
	} );
    
    [_beaconManager stopRangingBeaconsInRegion:_beaconRegion];

	[super viewDidDisappear:animated];
}

#pragma mark Orientation

- (BOOL)shouldAutorotate
{
	// Disable autorotation of the interface when recording is in progress.
//	return ! self.movieFileOutput.isRecording;
    return ! self.isRecording;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
	return UIInterfaceOrientationMaskAll;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
	[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

	// Note that the app delegate controls the device orientation notifications required to use the device orientation.
	UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
	if ( UIDeviceOrientationIsPortrait( deviceOrientation ) || UIDeviceOrientationIsLandscape( deviceOrientation ) ) {
		AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
		previewLayer.connection.videoOrientation = (AVCaptureVideoOrientation)deviceOrientation;
	}
}

#pragma mark KVO and Notifications

- (void)addObservers
{
	[self.session addObserver:self forKeyPath:@"running" options:NSKeyValueObservingOptionNew context:SessionRunningContext];
	[self.stillImageOutput addObserver:self forKeyPath:@"capturingStillImage" options:NSKeyValueObservingOptionNew context:CapturingStillImageContext];

//	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:self.videoDeviceInput.device];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:self.session];
	// A session can only run when the app is full screen. It will be interrupted in a multi-app layout, introduced in iOS 9,
	// see also the documentation of AVCaptureSessionInterruptionReason. Add observers to handle these session interruptions
	// and show a preview is paused message. See the documentation of AVCaptureSessionWasInterruptedNotification for other
	// interruption reasons.
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:self.session];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:self.session];
}

- (void)removeObservers
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];

	[self.session removeObserver:self forKeyPath:@"running" context:SessionRunningContext];
	[self.stillImageOutput removeObserver:self forKeyPath:@"capturingStillImage" context:CapturingStillImageContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
//    if ( [keyPath isEqualToString:@"adjustingExposure"] ) {
    if ( context == AdjustingExposureObservationContext ) {
//        if (![object isAdjustingExposure])
        if ( [[change objectForKey:NSKeyValueChangeNewKey] boolValue] == NO ) {
            dispatch_async( self.sessionQueue, ^{
                AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
                NSError *error = nil;
                if ([device lockForConfiguration:&error]) {
                    [device setExposureMode:AVCaptureExposureModeLocked];
                    [device unlockForConfiguration];
                } else {
                    NSLog( @"Could not lock device for configuration: %@", error );
                }
                NSLog(@" exposure locked ");
                
                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                [ud setFloat:_exposeFPS forKey:@"KEY_EXPOSE_FPS"];
                [ud setFloat:device.ISO forKey:@"KEY_ISO"];
//                [ud synchronize];
                NSLog(@"%.2f", device.ISO);
            });
        }
    }
//    if ( [keyPath isEqualToString:@"adjustingFocus"] ) {
    if ( context == AdjustingFocusObservationContext ) {
        if ( [[change objectForKey:NSKeyValueChangeNewKey] boolValue] == NO ) {
            dispatch_async( self.sessionQueue, ^{
                AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
                NSError *error = nil;
                if ([device lockForConfiguration:&error]) {
                    [device setExposureMode:AVCaptureExposureModeLocked];
                    [device unlockForConfiguration];
                } else {
                    NSLog( @"Could not lock device for configuration: %@", error );
                }
                NSLog(@" focus locked ");
                
                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                [ud setFloat:device.lensPosition forKey:@"KEY_LENSE_POS"];
//                [ud synchronize];
                NSLog(@"%.2f", device.lensPosition);
            });
        }
    }
	if ( context == CapturingStillImageContext ) {
		BOOL isCapturingStillImage = [change[NSKeyValueChangeNewKey] boolValue];

		if ( isCapturingStillImage ) {
			dispatch_async( dispatch_get_main_queue(), ^{
				self.previewView.layer.opacity = 0.0;
				[UIView animateWithDuration:0.25 animations:^{
					self.previewView.layer.opacity = 1.0;
				}];
			} );
		}
	}
	else if ( context == SessionRunningContext ) {
		BOOL isSessionRunning = [change[NSKeyValueChangeNewKey] boolValue];

		dispatch_async( dispatch_get_main_queue(), ^{
			// Only enable the ability to change camera if the device has more than one camera.
			self.cameraButton.enabled = isSessionRunning && ( [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo].count > 1 );
			self.recordButton.enabled = isSessionRunning;
			self.stillButton.enabled = isSessionRunning;
            self.videoButton.enabled = isSessionRunning;
		} );
	}
	else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

- (void)subjectAreaDidChange:(NSNotification *)notification
{
	CGPoint devicePoint = CGPointMake( 0.5, 0.5 );
	[self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
}

- (void)sessionRuntimeError:(NSNotification *)notification
{
	NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
	NSLog( @"Capture session runtime error: %@", error );

	// Automatically try to restart the session running if media services were reset and the last start running succeeded.
	// Otherwise, enable the user to try to resume the session running.
	if ( error.code == AVErrorMediaServicesWereReset ) {
		dispatch_async( self.sessionQueue, ^{
			if ( self.isSessionRunning ) {
				[self.session startRunning];
				self.sessionRunning = self.session.isRunning;
			}
			else {
				dispatch_async( dispatch_get_main_queue(), ^{
					self.resumeButton.hidden = NO;
				} );
			}
		} );
	}
	else {
		self.resumeButton.hidden = NO;
	}
}

- (void)sessionWasInterrupted:(NSNotification *)notification
{
	// In some scenarios we want to enable the user to resume the session running.
	// For example, if music playback is initiated via control center while using AVCam,
	// then the user can let AVCam resume the session running, which will stop music playback.
	// Note that stopping music playback in control center will not automatically resume the session running.
	// Also note that it is not always possible to resume, see -[resumeInterruptedSession:].
	BOOL showResumeButton = NO;

	// In iOS 9 and later, the userInfo dictionary contains information on why the session was interrupted.
	if ( &AVCaptureSessionInterruptionReasonKey ) {
		AVCaptureSessionInterruptionReason reason = [notification.userInfo[AVCaptureSessionInterruptionReasonKey] integerValue];
		NSLog( @"Capture session was interrupted with reason %ld", (long)reason );

		if ( reason == AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient ||
			 reason == AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient ) {
			showResumeButton = YES;
		}
		else if ( reason == AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps ) {
			// Simply fade-in a label to inform the user that the camera is unavailable.
			self.cameraUnavailableLabel.hidden = NO;
			self.cameraUnavailableLabel.alpha = 0.0;
			[UIView animateWithDuration:0.25 animations:^{
				self.cameraUnavailableLabel.alpha = 1.0;
			}];
		}
	}
	else {
		NSLog( @"Capture session was interrupted" );
		showResumeButton = ( [UIApplication sharedApplication].applicationState == UIApplicationStateInactive );
	}

	if ( showResumeButton ) {
		// Simply fade-in a button to enable the user to try to resume the session running.
		self.resumeButton.hidden = NO;
		self.resumeButton.alpha = 0.0;
		[UIView animateWithDuration:0.25 animations:^{
			self.resumeButton.alpha = 1.0;
		}];
	}
}

- (void)sessionInterruptionEnded:(NSNotification *)notification
{
	NSLog( @"Capture session interruption ended" );

	if ( ! self.resumeButton.hidden ) {
		[UIView animateWithDuration:0.25 animations:^{
			self.resumeButton.alpha = 0.0;
		} completion:^( BOOL finished ) {
			self.resumeButton.hidden = YES;
		}];
	}
	if ( ! self.cameraUnavailableLabel.hidden ) {
		[UIView animateWithDuration:0.25 animations:^{
			self.cameraUnavailableLabel.alpha = 0.0;
		} completion:^( BOOL finished ) {
			self.cameraUnavailableLabel.hidden = YES;
		}];
	}
}

#pragma mark Actions

- (IBAction)resumeInterruptedSession:(id)sender
{
	dispatch_async( self.sessionQueue, ^{
		// The session might fail to start running, e.g., if a phone or FaceTime call is still using audio or video.
		// A failure to start the session running will be communicated via a session runtime error notification.
		// To avoid repeatedly failing to start the session running, we only try to restart the session running in the
		// session runtime error handler if we aren't trying to resume the session running.
		[self.session startRunning];
		self.sessionRunning = self.session.isRunning;
		if ( ! self.session.isRunning ) {
			dispatch_async( dispatch_get_main_queue(), ^{
				NSString *message = NSLocalizedString( @"Unable to resume", @"Alert message when unable to resume the session running" );
				UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
				UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
				[alertController addAction:cancelAction];
				[self presentViewController:alertController animated:YES completion:nil];
			} );
		}
		else {
			dispatch_async( dispatch_get_main_queue(), ^{
				self.resumeButton.hidden = YES;
			} );
		}
	} );
}

- (IBAction)changeCamera:(id)sender
{
	self.cameraButton.enabled = NO;
	self.recordButton.enabled = NO;
	self.stillButton.enabled = NO;
    self.videoButton.enabled = NO;

	dispatch_async( self.sessionQueue, ^{
		AVCaptureDevice *currentVideoDevice = self.videoDeviceInput.device;
		AVCaptureDevicePosition preferredPosition = AVCaptureDevicePositionUnspecified;
		AVCaptureDevicePosition currentPosition = currentVideoDevice.position;

		switch ( currentPosition )
		{
			case AVCaptureDevicePositionUnspecified:
			case AVCaptureDevicePositionFront:
				preferredPosition = AVCaptureDevicePositionBack;
				break;
			case AVCaptureDevicePositionBack:
				preferredPosition = AVCaptureDevicePositionFront;
				break;
		}

		AVCaptureDevice *videoDevice = [AAPLCameraViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:preferredPosition];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];

		[self.session beginConfiguration];

		// Remove the existing device input first, since using the front and back camera simultaneously is not supported.
		[self.session removeInput:self.videoDeviceInput];

		if ( [self.session canAddInput:videoDeviceInput] ) {
			[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];

			[AAPLCameraViewController setFlashMode:AVCaptureFlashModeAuto forDevice:videoDevice];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:videoDevice];

			[self.session addInput:videoDeviceInput];
			self.videoDeviceInput = videoDeviceInput;
		}
		else {
			[self.session addInput:self.videoDeviceInput];
		}

		AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
		if ( connection.isVideoStabilizationSupported ) {
			connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
		}

		[self.session commitConfiguration];

		dispatch_async( dispatch_get_main_queue(), ^{
			self.cameraButton.enabled = YES;
			self.recordButton.enabled = YES;
			self.stillButton.enabled = YES;
            self.videoButton.enabled = YES;
		} );
	} );
}

- (IBAction)pushLogButton:(id)sender {
    
    [self recordBeacon: _videoFileName withStartTime:[self timeStamp]];
}

- (IBAction)toggleVideoRecording:(id)sender {
    // Disable the Camera button until recording finishes, and disable the Record button until recording starts or finishes. See the
    // AVCaptureFileOutputRecordingDelegate methods.
    self.cameraButton.enabled = NO;
    self.videoButton.enabled = NO;
    
    if (_isRecording == YES) {
        _isRecording = NO;
        _isVideoing = NO;
    } else {
        if ([self.session canAddOutput:_movieFileOutput]) {
            [self.session addOutput:_movieFileOutput];
        }
        
        _videoFileName = [self timeStamp];
        _isRecording = YES;
        _isVideoing = YES;
        [self startBeaconSampling];
        [self recordBeacon: _videoFileName withStartTime:_videoFileName];
    }
    
    
    dispatch_async( self.sessionQueue, ^{
        if ( ! self.movieFileOutput.isRecording ) {
            if ( [UIDevice currentDevice].isMultitaskingSupported ) {
                // Setup background task. This is needed because the -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:]
                // callback is not received until AVCam returns to the foreground unless you request background execution time.
                // This also ensures that there will be time to write the file to the photo library when AVCam is backgrounded.
                // To conclude this background execution, -endBackgroundTask is called in
                // -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:] after the recorded file has been saved.
                self.backgroundRecordingID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
            }
            
            // Update the orientation on the movie file output video connection before starting recording.
            AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
            AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
            connection.videoOrientation = previewLayer.connection.videoOrientation;
            
            
            // Turn OFF flash for video recording.
            [AAPLCameraViewController setFlashMode:AVCaptureFlashModeOff forDevice:self.videoDeviceInput.device];
            
            // Start recording to a temporary file.
            NSString *outputFileName = [NSProcessInfo processInfo].globallyUniqueString;
            NSString *outputFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[outputFileName stringByAppendingPathExtension:@"mov"]];
            [self.movieFileOutput startRecordingToOutputFileURL:[NSURL fileURLWithPath:outputFilePath] recordingDelegate:self];
        }
        else {
            [self.movieFileOutput stopRecording];
        }
    } );
}

- (IBAction)toggleImageSeqRecording:(id)sender
{
//    if (![self.session canAddOutput:_movieFileOutput])
//        [self.session removeOutput:_movieFileOutput];
    
    // Disable the Camera button until recording finishes, and disable the Record button until recording starts or finishes. See the
    // AVCaptureFileOutputRecordingDelegate methods.
    self.cameraButton.enabled = NO;
    self.recordButton.enabled = NO;
    
    if (_isRecording == YES) {
        _isRecording = NO;
        if ([_timberImgseq isValid]) {
            [_timberImgseq invalidate];
            _timberImgseq = nil;
        }
//        [self disposeBeaconSampling];
//        [self recordBeacon: _videoFileName];
    } else {
        _videoFileName = [self timeStamp];
        _isRecording = YES;
        [self startBeaconSampling];
        if (!_timberImgseq) {
            _timberImgseq = [NSTimer scheduledTimerWithTimeInterval:1
                                                             target:self
                                                           selector:@selector(grabOneFrame)
                                                           userInfo:nil
                                                            repeats:YES];
        }
        [_timberImgseq fire];
    }
    
    dispatch_async( dispatch_get_main_queue(), ^{
        if (_isRecording == YES) {
            
            self.recordButton.enabled = YES;
            [self.recordButton setTitle:NSLocalizedString( @"Stop", @"Recording button stop title" ) forState:UIControlStateNormal];
        } else {
            self.cameraButton.enabled = ( [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo].count > 1 );
            self.recordButton.enabled = YES;
            [self.recordButton setTitle:NSLocalizedString( @"Record", @"Recording button record title") forState:UIControlStateNormal];
            
            
        }
        self.estBeaconLabel.text = @"";
    });


}

- (IBAction)snapStillImage:(id)sender
{
    _currentSmpNum = 0;
    _targetSmpNum = 1;
    [self grabOneFrame];
}


- (void)grabOneFrame {
    NSString *imageFileName = [self timeStamp];
    
    dispatch_async( self.sessionQueue, ^{
        AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
        AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
        
        // Update the orientation on the still image output video connection before capturing.
        connection.videoOrientation = previewLayer.connection.videoOrientation;
        
        // Flash set to Auto for Still Capture.
        [AAPLCameraViewController setFlashMode:AVCaptureFlashModeAuto forDevice:self.videoDeviceInput.device];
        
        // Capture a still image.
        [self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler:^( CMSampleBufferRef imageDataSampleBuffer, NSError *error ) {
            if ( imageDataSampleBuffer ) {
                // The sample buffer is not retained. Create image data before saving the still image to the photo library asynchronously.
                NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
                //Writing the image file
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                    // Create folder
                    NSError *error;
                    NSString *documentPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
                    NSString *imgPath = [documentPath stringByAppendingPathComponent:imageFileName];
                    if (![[NSFileManager defaultManager] fileExistsAtPath:imgPath]) { // exists?
                        if (![[NSFileManager defaultManager] createDirectoryAtPath:imgPath withIntermediateDirectories:NO attributes:nil error:&error]) {
                            NSLog(@"Create directory error: %@", error);
                        }
                    }
                    // Save it into file system
                    // NSString *savedImagePath = [documentPath stringByAppendingPathComponent:@"myImage.png"];
                    NSString *imageFilePath = [imgPath stringByAppendingPathComponent:[imageFileName stringByAppendingPathExtension:@"jpg"]];
                    [imageData writeToFile:imageFilePath atomically:YES];
                    // NSLog( @"Photo saved path: %@", imageFilePath );
                    
                    // [self sendImageToServer:imageData withImageName:imageFilePath];
                });
                
                [self sendImageToServer:imageData withImageName:[imageFileName stringByAppendingPathExtension:@"jpg"]];
                
            } else {
                NSLog( @"Could not capture still image: %@", error );
            }
        }];
    } );
    
    [self recordBeacon: imageFileName];
}

- (IBAction)focusAndExposeTap:(UIGestureRecognizer *)gestureRecognizer
{
//	CGPoint devicePoint = [(AVCaptureVideoPreviewLayer *)self.previewView.layer captureDevicePointOfInterestForPoint:[gestureRecognizer locationInView:gestureRecognizer.view]];
//	[self focusWithMode:AVCaptureFocusModeAutoFocus exposeWithMode:AVCaptureExposureModeAutoExpose atDevicePoint:devicePoint monitorSubjectAreaChange:YES];
//    
//    CGPoint point= [gestureRecognizer locationInView:self.previewView];
//    [self setFocusCursorWithPoint:point];
    
    [self hideKeyboard];
}

#pragma mark File Output Recording Delegate (frames)

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)imageDataSampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    return;
    if ( _isRecording ) {
        
        if ( imageDataSampleBuffer ) {
//            NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
            
            NSData *imageData = UIImagePNGRepresentation([self imageFromSampleBuffer:imageDataSampleBuffer]);
            NSString *frameFileName = [self timeStamp];
            
//            dispatch_async( self.sessionQueue, ^{
            dispatch_async( self.imgSeqQueue, ^{
                
            // Update the orientation on the movie file output video connection before starting recording.
            AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
            AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
            connection.videoOrientation = previewLayer.connection.videoOrientation;
            
                //Writing the image file
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
//                dispatch_async(self.imgSeqQueue, ^{
                
                    NSError *error;
                    NSString *documentPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
                    NSString *imgPath = [documentPath stringByAppendingPathComponent:_videoFileName];
                    if (![[NSFileManager defaultManager] fileExistsAtPath:imgPath]) { // exists?
                        if (![[NSFileManager defaultManager] createDirectoryAtPath:imgPath withIntermediateDirectories:NO attributes:nil error:&error]) {
                            NSLog(@"Create directory error: %@", error);
                        }
                    }
                    // Save it into file system
                    NSString *frameFilePath = [imgPath stringByAppendingPathComponent:[frameFileName stringByAppendingPathExtension:@"jpg"]];
//                    NSLog( @"Frame image saved path: %@", _videoFileName );
                    [imageData writeToFile:frameFilePath atomically:YES];
                });
            });
            
            [self sendImageToServer:imageData withImageName:[frameFileName stringByAppendingPathExtension:@"jpg"]];
//            NSLog(@"----- 8 -------\n");
            [self recordBeacon: _videoFileName withFrame: frameFileName];
            
        }
    }
}

#pragma mark File Output Recording Delegate

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray *)connections
{
    NSLog( @"Video file Delegate+start method called." );
    
	// Enable the Record button to let the user stop the recording.
	dispatch_async( dispatch_get_main_queue(), ^{
        self.estBeaconLabel.text = @"";
		self.videoButton.enabled = YES;
		[self.videoButton setTitle:NSLocalizedString( @"Stop", @"Videoing button stop title") forState:UIControlStateNormal];
	});
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
    NSLog( @"Video file Delegate+finish method called." );
	// Note that currentBackgroundRecordingID is used to end the background task associated with this recording.
	// This allows a new recording to be started, associated with a new UIBackgroundTaskIdentifier, once the movie file output's isRecording property
	// is back to NO — which happens sometime after this method returns.
	// Note: Since we use a unique file path for each recording, a new recording will not overwrite a recording currently being saved.
	UIBackgroundTaskIdentifier currentBackgroundRecordingID = self.backgroundRecordingID;
	self.backgroundRecordingID = UIBackgroundTaskInvalid;

	dispatch_block_t cleanup = ^{
		[[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
		if ( currentBackgroundRecordingID != UIBackgroundTaskInvalid ) {
			[[UIApplication sharedApplication] endBackgroundTask:currentBackgroundRecordingID];
		}
	};

	BOOL success = YES;

	if ( error ) {
		NSLog( @"Movie file finishing error: %@", error );
		success = [error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue];
	}
	if ( success ) {
        
        //Writing the video file
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
            
            // Create folder
            NSError *error;
            NSString *documentPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
            NSString *vidPath = [documentPath stringByAppendingPathComponent:_videoFileName];
            NSString *vidFilePath = [vidPath stringByAppendingPathExtension:@"mov"];
            // Save it into file system
//            NSLog( @"+ video %@ saved path: %@", [outputFileURL path], vidPath );
            if ( ![[NSFileManager defaultManager] copyItemAtPath:[outputFileURL path] toPath:vidFilePath error:&error] ) {
                NSLog(@"Copy video failed error: %@ \t %@", error, [outputFileURL path] );
                cleanup();
            }
        });
        
//        [self recordBeacon: videoFileName];
	}
	else {
		cleanup();
	}

	// Enable the Camera and Record buttons to let the user switch camera and start another recording.
	dispatch_async( dispatch_get_main_queue(), ^{
		// Only enable the ability to change camera if the device has more than one camera.
		self.cameraButton.enabled = ( [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo].count > 1 );
		self.videoButton.enabled = YES;
		[self.videoButton setTitle:NSLocalizedString( @"Video", @"Videoing button record title" ) forState:UIControlStateNormal];
	});
    
}

#pragma mark Device Configuration

- (void)setandfixFocusExplosure {
    //    dispatch_async( self.sessionQueue, ^{
    AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    
    _exposeFPS = self.fpsSlider.value;
    
    if ([device lockForConfiguration:nil]) {
        device.focusMode = AVCaptureFocusModeLocked;
        device.exposureMode = AVCaptureExposureModeLocked;
        _lensPosition = device.lensPosition;
        _ISO = device.ISO;
        [ud setFloat:device.lensPosition forKey:@"KEY_LENSE_POS"];
        [ud setFloat:_exposeFPS forKey:@"KEY_EXPOSE_FPS"];
        [ud setFloat:device.ISO forKey:@"KEY_ISO"];
        [device unlockForConfiguration];
    }
    
    dispatch_async( dispatch_get_main_queue(), ^{
        NSLog(@"Fix exposure: %.2f, %.2f, %.2f+F", _exposeFPS, _ISO, _lensPosition);
        self.fpsLabel.text = [NSString stringWithFormat:@"%.0f, %.2f, %.2f+F", _exposeFPS, _ISO, _lensPosition];
    });
}

- (void)fixFocusExplosure {

    //    dispatch_async( self.sessionQueue, ^{
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
    NSError *error = nil;
    int minWidth = 1280, minHeight = 720;
    float minFov = 58.0;
    Float64 maxFrameRate = .0f;
    AVCaptureDeviceFormat *targetFormat = nil;
    NSArray *formats = device.formats;
    for (AVCaptureDeviceFormat *format in formats) {
        AVFrameRateRange *frameRateRange = format.videoSupportedFrameRateRanges[0];
        Float64 frameRate = frameRateRange.maxFrameRate;
        
        CMFormatDescriptionRef desc = format.formatDescription;
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(desc);
        int32_t width = dimensions.width;
        int32_t height = dimensions.height;
        float fov = format.videoFieldOfView;
        if (frameRate >= maxFrameRate && width >= minWidth && height >= minHeight && fov >= minFov) {
            targetFormat = format;
            maxFrameRate = frameRate;
        }
    }
    if (targetFormat && [device lockForConfiguration:&error]) {
        device.activeFormat = targetFormat;
        device.activeVideoMaxFrameDuration = CMTimeMake(1, maxFrameRate);
        device.activeVideoMinFrameDuration = CMTimeMake(1, maxFrameRate);
        [device unlockForConfiguration];
        _exposeFPS = maxFrameRate;
    }
    
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        float lensePos = [ud floatForKey:@"KEY_LENSE_POS"];
        if (lensePos > .0) {
            NSLog(@" Loaded saved lense position : %.5f", lensePos);
            if ([device lockForConfiguration:nil]) {
                [device setFocusModeLockedWithLensPosition:lensePos completionHandler:^(CMTime syncTime) {
                    _lensPosition = lensePos;
                }];
                [device unlockForConfiguration];
            }
        } else {
            if ([device lockForConfiguration:nil]) {
                device.focusMode = AVCaptureFocusModeLocked;
                [device unlockForConfiguration];
            }
        }
        
        float fps = [ud floatForKey:@"KEY_EXPOSE_FPS"];
        float iso = [ud floatForKey:@"KEY_ISO"];
        if (fps > 0.0 && iso > 0.0) {
            NSLog(@" Loaded saved FPS for exposure duration : %.5f", fps);
            NSLog(@" Loaded saved ISO : %.5f", iso);
            
            if ([device lockForConfiguration:nil]) {
                CMTime duration = CMTimeMake(1, fps);
                [device setExposureModeCustomWithDuration:duration ISO:iso completionHandler:^(CMTime syncTime) {
                    _ISO = iso;
                    _exposeFPS = fps;
                    
                }];
                [device unlockForConfiguration];
            }
        } else {
            if ([device lockForConfiguration:nil]) {
                device.exposureMode = AVCaptureExposureModeLocked;
                [device unlockForConfiguration];
            }
            
        }

        dispatch_async( dispatch_get_main_queue(), ^{
            NSLog(@"Fix exposure: %.2f, %.2f, %.2f", _exposeFPS, device.ISO, device.lensPosition);
            self.fpsLabel.text = [NSString stringWithFormat:@"%.0f, %.2f, %.2f", _exposeFPS, _ISO, _lensPosition];
        });
    
//    } );
}

- (void)focusWithMode:(AVCaptureFocusMode)focusMode exposeWithMode:(AVCaptureExposureMode)exposureMode atDevicePoint:(CGPoint)point monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange
{
	dispatch_async( self.sessionQueue, ^{
		AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
		NSError *error = nil;
		if ( [device lockForConfiguration:&error] ) {
			// Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
			// Call -set(Focus/Exposure)Mode: to apply the new point of interest.
			if ( device.isFocusPointOfInterestSupported && [device isFocusModeSupported:focusMode] ) {
				device.focusPointOfInterest = point;
				device.focusMode = focusMode;
			}

			if ( device.isExposurePointOfInterestSupported && [device isExposureModeSupported:exposureMode] ) {
				device.exposurePointOfInterest = point;
				device.exposureMode = exposureMode;
			}

			device.subjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange;
			[device unlockForConfiguration];
		}
		else {
			NSLog( @"Could not lock device for configuration: %@", error );
		}
        
        dispatch_async( dispatch_get_main_queue(), ^{
            NSLog( @"fps:%.2f, ISO:%.2f, Lens:%.2f", _exposeFPS, device.ISO, device.lensPosition );
            self.fpsLabel.text = [NSString stringWithFormat:@"%.0f, %.2f, %.2f+A", _exposeFPS, device.ISO, device.lensPosition];
        });
        
        
//        if ( [[change objectForKey:NSKeyValueChangeNewKey] boolValue] == NO ) {
//            dispatch_async( self.sessionQueue, ^{
//                AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
//                if ([device lockForConfiguration:nil]) {
//                    [device setExposureMode:AVCaptureExposureModeLocked];
//                    [device unlockForConfiguration];
//                }
//                NSLog(@" exposure locked ");
//                
//                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
//                [ud setFloat:_exposeFPS forKey:@"KEY_EXPOSE_FPS"];
//                [ud setFloat:device.ISO forKey:@"KEY_ISO"];
//                [ud setFloat:device.lensPosition forKey:@"KEY_LENSE_POS"];
//                [ud synchronize];
//                NSLog(@"%.2f", device.ISO);
//            });
//        }
	} );
}

+ (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device
{
	if ( device.hasFlash && [device isFlashModeSupported:flashMode] ) {
		NSError *error = nil;
		if ( [device lockForConfiguration:&error] ) {
			device.flashMode = flashMode;
			[device unlockForConfiguration];
		}
		else {
			NSLog( @"Could not lock device for configuration: %@", error );
		}
	}
}

+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
	AVCaptureDevice *captureDevice = devices.firstObject;

	for ( AVCaptureDevice *device in devices ) {
		if ( device.position == position ) {
			captureDevice = device;
			break;
		}
	}

	return captureDevice;
}

// Create a UIImage from sample buffer data
- (UIImage *) imageFromSampleBuffer:(CMSampleBufferRef) sampleBuffer
{
    // Get a CMSampleBuffer's Core Video image buffer for the media data
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    // Lock the base address of the pixel buffer
    CVPixelBufferLockBaseAddress(imageBuffer, 0);
    
    // Get the number of bytes per row for the pixel buffer
    void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
    
    // Get the number of bytes per row for the pixel buffer
    size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
    // Get the pixel buffer width and height
    size_t width = CVPixelBufferGetWidth(imageBuffer);
    size_t height = CVPixelBufferGetHeight(imageBuffer);
    
    // Create a device-dependent RGB color space
    CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
    
    // Create a bitmap graphics context with the sample buffer data
    CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8,
                                                 bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    // Create a Quartz image from the pixel data in the bitmap graphics context
    CGImageRef quartzImage = CGBitmapContextCreateImage(context);
    // Unlock the pixel buffer
    CVPixelBufferUnlockBaseAddress(imageBuffer,0);
    
    // Free up the context and color space
    CGContextRelease(context);
    CGColorSpaceRelease(colorSpace);
    
    // Create an image object from the Quartz image
    UIImage *image = [UIImage imageWithCGImage:quartzImage];
    
    // Release the Quartz image
    CGImageRelease(quartzImage);
    
    return (image);
}

- (IBAction)toggleFixFocusExposure:(id)sender {
    [self setandfixFocusExplosure];
}

- (IBAction)slideFPSChanged:(UISlider *)sender {
        
    dispatch_async( self.sessionQueue, ^{
            
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        dispatch_async( dispatch_get_main_queue(), ^{
        //            NSLog(@"Fix exposure: %.2f, %.2f, %.2f", _exposeFPS, device.ISO, device.lensPosition);
            _exposeFPS = [sender value];
            self.fpsLabel.text = [NSString stringWithFormat:@"%.0f, %.2f, %.2f+A", _exposeFPS, device.ISO, device.lensPosition];
        });
    });
    
}

- (void)startFocus {
//    [[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo] addObserver:self forKeyPath:@"adjustingFocus" options:NSKeyValueObservingOptionNew context:nil];
//    [[AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo] addObserver:self forKeyPath:@"adjustingExposure" options:NSKeyValueObservingOptionNew context:nil];
    
    dispatch_async( self.sessionQueue, ^{
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        
        [device addObserver:self forKeyPath:@"adjustingFocus" options:NSKeyValueObservingOptionNew context:AdjustingFocusObservationContext];
        [device addObserver:self forKeyPath:@"adjustingExposure" options:NSKeyValueObservingOptionNew context:AdjustingExposureObservationContext];
        NSLog(@"startFocus now");
    });
}

- (void)stopFocus {
    dispatch_async( self.sessionQueue, ^{
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        
        if ([device lockForConfiguration:nil]) {
            device.focusMode = AVCaptureFocusModeLocked;
            device.exposureMode = AVCaptureExposureModeLocked;
            [device unlockForConfiguration];
        }
        
        [device removeObserver:self forKeyPath:@"adjustingFocus" context:AdjustingFocusObservationContext];
        [device removeObserver:self forKeyPath:@"adjustingExposure" context:AdjustingExposureObservationContext];
    });
    NSLog(@"stopFocus now");
}

- (void)setFocusCursorWithPoint:(CGPoint)point {
    
//    NSLog(@"%.3f, %.3f\n", point.x, point.y);
    
    self.focusCursor.center = point;
    self.focusCursor.alpha = 0.6;
    self.focusCursor.transform = CGAffineTransformMakeScale(1.2, 1.2);
    [UIView animateWithDuration:1.0 animations:^{
        self.focusCursor.transform = CGAffineTransformIdentity;
    } completion:^(BOOL finished) {
        self.focusCursor.alpha = 0;
    }];
}

- (void)initFocusCursor {
    
//    _focusCursor = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 50, 50)];
//    _focusCursor.userInteractionEnabled = YES;
//    _focusCursor.center = self.previewView.center;
//    _focusCursor.backgroundColor = [UIColor colorWithRed:0.6 green:0.6 blue:0.0 alpha:0.6];
//    
//    [self.previewView addSubview:_focusCursor];
    
    [self fixFocusExplosure];
    
    self.fpsSlider.minimumValue = 0;
    self.fpsSlider.maximumValue = 60;
    self.fpsSlider.value = _exposeFPS;
    
    dispatch_async( self.sessionQueue, ^{
        
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        dispatch_async( dispatch_get_main_queue(), ^{
            //            NSLog(@"Fix exposure: %.2f, %.2f, %.2f", _exposeFPS, device.ISO, device.lensPosition);
            self.fpsLabel.text = [NSString stringWithFormat:@"%.0f, %.2f, %.2f", self.fpsSlider.value, device.ISO, device.lensPosition];
        });
    });
}

- (void)initBeacon
{
    _xTextField.text = [NSString stringWithFormat:@"%.1f", 0.0];
    _yTextField.text = [NSString stringWithFormat:@"%.1f", 0.0];
//    _xAutoModeSeg.enabled = false;
//    _yAutoModeSeg.enabled = false;
    _pickerStrs = @[@"1", @"2",@"5",@"10",@"15",@"20",@"25",@"30",@"35",@"40",@"45",@"50",@"55",@"60"];
    _currentSmpNum = 0;
    _targetSmpNum = 1;
//    _sampleNumPicker.dataSource = self;
//    _sampleNumPicker.delegate = self;
//    _sampleNumPicker.userInteractionEnabled = true;
//    [_sampleNumPicker selectRow:0 inComponent:0 animated:false];
//    _beaconFilterString = _beaconFilterTextView.text;

    _uuid = [[NSUUID alloc] initWithUUIDString:@"f7826da6-4fa2-4e98-8024-bc5b71e0893e"];
    _beaconManager = [[CLLocationManager alloc] init];
    
    if([_beaconManager respondsToSelector:@selector(requestAlwaysAuthorization)]) {
        [_beaconManager requestAlwaysAuthorization];
    }
    _beaconManager.delegate = self;
    _beaconManager.pausesLocationUpdatesAutomatically = NO;
    _beaconRegion = [[CLBeaconRegion alloc] initWithProximityUUID:_uuid major:65535 identifier:@"cmaccess"];
    [_beaconManager startRangingBeaconsInRegion:_beaconRegion];
    _isSampling = false;
}

- (void)recordImgEstimation:(NSString*) data to:(NSString*) name {
    NSMutableString *fileName = [[NSMutableString alloc] init];
//    [fileName appendString:@"/still_img_estPosition.txt"];
    [fileName appendString:name];
    NSString *documentPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *filePath = [documentPath stringByAppendingString:fileName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
        [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
    NSFileHandle* estPositionDataFile = [NSFileHandle fileHandleForWritingAtPath:filePath];
    [estPositionDataFile seekToEndOfFile];
    [estPositionDataFile writeData:[data dataUsingEncoding:NSUTF8StringEncoding]];
    [estPositionDataFile closeFile];
}

- (IBAction)xStepperValueChanged:(id)sender {
//    _xTextField.text = [NSString stringWithFormat:@"%.1f", _xStepper.value];
}


- (IBAction)yStepperValueChanged:(id)sender {
//    _yTextField.text = [NSString stringWithFormat:@"%.1f", _yStepper.value];
}

- (IBAction)xAutoModeChanged:(id)sender {
//    if (_xAutoModeSeg.selectedSegmentIndex == 0) {
//        _xAutoMode = AutoDec;
//    } else {
//        _xAutoMode = AutoInc;
//    }
}

- (IBAction)yAutoModeChanged:(id)sender {
//    if (_yAutoModeSeg.selectedSegmentIndex == 0) {
//        _yAutoMode = AutoDec;
//    } else {
//        _yAutoMode = AutoInc;
//    }
}

- (NSSet *)analysisBeaconFilter:(NSString *)str {
    NSMutableSet *result = [[NSMutableSet alloc] init];
    NSArray *splits = [str componentsSeparatedByString:@","];
    for (NSString *split in splits) {
        if ([split containsString:@"-"]) {
            NSScanner *scanner = [NSScanner scannerWithString:split];
            NSInteger startID;
            NSInteger endID;
            [scanner scanInteger:&startID];
            [scanner scanInteger:&endID];
            int start = (int)startID;
            int end = abs((int)endID);
            for (int i = start; i <= end; i++) {
                [result addObject:[NSString stringWithFormat:@"%d", i]];
            }
        } else {
            NSScanner *scanner = [NSScanner scannerWithString:split];
            NSInteger beaconId;
            [scanner scanInteger:&beaconId];
            [result addObject:[NSString stringWithFormat:@"%ld", beaconId]];
        }
    }
    return result;
}

- (void)hideKeyboard {
    [_xTextField resignFirstResponder];
    [_yTextField resignFirstResponder];
//    [_beaconFilterTextView resignFirstResponder];
//    [_edgeIDTextField resignFirstResponder];
}

- (NSInteger)pickerView:(UIPickerView *)pickerView numberOfRowsInComponent:(NSInteger)component {
    return 12;
}

- (NSInteger)numberOfComponentsInPickerView:(UIPickerView *)pickerView {
    return 1;
}

- (NSString *)pickerView:(UIPickerView *)pickerView titleForRow:(NSInteger)row forComponent:(NSInteger)component {
    return [_pickerStrs objectAtIndex:row];
}

- (void)pickerView:(UIPickerView *)pickerView didSelectRow:(NSInteger)row inComponent:(NSInteger)component {
    _targetSmpNum = ((NSString *)([_pickerStrs objectAtIndex:row])).intValue;
}

- (void)recordBeacon:(NSString *)videoFolderPath withStartTime:(NSString *)time {
    
    NSMutableString *fileName = [[NSMutableString alloc] init];
    [fileName appendString:@"/video"];
    [fileName appendFormat:@"_signal_%@.txt", videoFolderPath];
    NSString *documentPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *filePath = [documentPath stringByAppendingString:fileName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
        _dataFile = [NSFileHandle fileHandleForWritingAtPath:filePath];
    }
    _isSampling = true;
    
    
    NSFileHandle *dataCoorFile;
    NSMutableString *fileCoorName = [[NSMutableString alloc] init];
    [fileCoorName appendString:@"/video"];
    [fileCoorName appendFormat:@"_coodinate_%@.txt", videoFolderPath];
    NSString *fileCoorPath = [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0] stringByAppendingString:fileCoorName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:fileCoorPath]) {
        [[NSFileManager defaultManager] createFileAtPath:fileCoorPath contents:nil attributes:nil];
    }
    dataCoorFile = [NSFileHandle fileHandleForWritingAtPath:fileCoorPath];
    [dataCoorFile seekToEndOfFile];
    NSMutableString *strLine = [[NSMutableString alloc] init];
    [strLine appendFormat:@"%@,Misc,Video,", time];
    [strLine appendFormat:@"%.2f,%.2f\n", _xTextField.text.floatValue, _yTextField.text.floatValue];
    [dataCoorFile writeData:[strLine dataUsingEncoding:NSUTF8StringEncoding]];
    [dataCoorFile closeFile];
    
}

- (void)recordBeacon:(NSString *)frameFolderPath withFrame:(NSString *)filename {
    
    NSMutableString *fileName = [[NSMutableString alloc] init];
    [fileName appendFormat:@"/%@.txt", frameFolderPath];
    NSString *documentPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *filePath = [documentPath stringByAppendingString:fileName];
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath])
        [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
    _dataFile = [NSFileHandle fileHandleForWritingAtPath:filePath];
    [_dataFile seekToEndOfFile];
    NSMutableString *strLine = [[NSMutableString alloc] init];
    
    
    [strLine appendFormat:@"%@,Misc,Photo,%@.jpg\n", [self timeStamp],filename];
    [_dataFile writeData:[strLine dataUsingEncoding:NSUTF8StringEncoding]];
    _isSampling = true;
}

- (void)recordBeacon:(NSString *) imageFileName {
//    _xStepper.value = _xTextField.text.floatValue;
//    _yStepper.value = _yTextField.text.floatValue;
    
//    _currentSmpNum = 0;
//    _targetSmpNum = 1;
    
//    _countDownLabel.text = [NSString stringWithFormat:@"%d", _targetSmpNum];
    
//    if (![_beaconFilterString isEqualToString:_beaconFilterTextView.text]) {
//        _beaconFilterString = _beaconFilterTextView.text;
//        _beaconMinors = [self analysisBeaconFilter:_beaconFilterString];
//    }
    
    NSMutableString *fileName = [[NSMutableString alloc] init];
    [fileName appendString:@"/data"];
//    [fileName appendString:_edgeIDTextField.text];
    [fileName appendFormat:@"_%.1f_%.1f_%@.txt", _xTextField.text.floatValue, _yTextField.text.floatValue, imageFileName];
    NSString *documentPath = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) objectAtIndex:0];
    NSString *filePath = [documentPath stringByAppendingString:fileName];
    [[NSFileManager defaultManager] createFileAtPath:filePath contents:nil attributes:nil];
    _dataFile = [NSFileHandle fileHandleForWritingAtPath:filePath];
    NSMutableString *strLine = [[NSMutableString alloc] init];
//    [strLine appendFormat:@"MinorID of %ld Beacon Used : ", _beaconMinors.count];
//    int *beaconMinorIDs = malloc(sizeof(int) * _beaconMinors.count);
//    int i = 0;
//    for (NSString *str in _beaconMinors) {
//        beaconMinorIDs[i] = str.intValue;
//        i++;
//    }
//    qsort_b(beaconMinorIDs, i, sizeof(int), ^int(const void *p1, const void *p2) {
//        const int *x1 = p1;
//        const int *x2 = p2;
//        
//        if (*x1 > *x2) {
//            return 1;
//        } else {
//            return -1;
//        }
//    });
//    
//    for (int j = 0; j < _beaconMinors.count; j++) {
//        [strLine appendFormat:@"%d,", beaconMinorIDs[j]];
//    }
//    
//    [strLine appendString:@"\n"];
    [strLine appendFormat:@"%@,Misc,Photo,%@.jpg\n", [self timeStamp],imageFileName];
    [_dataFile writeData:[strLine dataUsingEncoding:NSUTF8StringEncoding]];
    _isSampling = true;
}

//#iBeacon data callback

- (void)locationManager:(CLLocationManager *)manager didRangeBeacons:(NSArray *)beacons inRegion:(CLBeaconRegion *)region {
    
//    [self drawChart:nil];
    
    if (!_isSampling) {
        return;
    }
    
    if (_currentSmpNum >= _targetSmpNum) {
        return;
    }
    
//    NSMutableString* sss = [[NSMutableString alloc] init];
//    [sss appendString:@"1449708154770,Beacon,22,65535,198,-100,65535,87,-100,65535,7,-100,65535,8,-100,65535,1,-73,65535,175,-75,65535,190,-82,65535,5,-76,65535,193,-81,65535,3,-84,65535,188,-78,65535,195,-84,65535,189,-84,65535,194,-87,65535,191,-88,65535,199,-86,65535,4,-88,65535,192,-90,65535,196,-93,65535,197,-91,65535,200,-94,65535,134,-92,"];
//    [self sendBeaconDataToServer:sss withID:@"1449708154770"];
    
//    int validBeaconCount = 0;
//    if (beacons.count > 0) {
//        for (CLBeacon *beacon in beacons) {
//            NSString *minorID = [NSString stringWithFormat:@"%d", [beacon.minor intValue]];
//            if ([_beaconMinors containsObject:minorID]) {
//                validBeaconCount++;
//            }
//        }
//    }
    
    int validBeaconCount = (int)beacons.count;
    
    if (validBeaconCount > 0) {
        NSLog(@"iBeacon sampling recording.");
        NSMutableString *strLine = [[NSMutableString alloc] init];
        NSString* beaconTimeStamp = [self timeStamp];
        [strLine appendFormat:@"%@,Beacon,", beaconTimeStamp];
//        [strLine appendString:_xTextField.text];
//        [strLine appendString:@","];
//        [strLine appendString:_yTextField.text];
//        [strLine appendString:@","];
        [strLine appendFormat:@"%d,", validBeaconCount];
        for (CLBeacon *beacon in beacons) {
            NSString *minorID = [NSString stringWithFormat:@"%d", [beacon.minor intValue]];
//            if ([_beaconMinors containsObject:minorID]) {
                NSString *majorID = [NSString stringWithFormat:@"%d", [beacon.major intValue]];
                [strLine appendString:majorID];
                [strLine appendString:@","];
                [strLine appendString:minorID];
                [strLine appendString:@","];
                int rssi = (int)beacon.rssi;
                if (rssi == 0) {
                    rssi = -100;
                }
                [strLine appendFormat:@"%d", rssi];
                [strLine appendString:@","];
//            }
        }
        //        char Path[1000];
        //        if (_dataFile && fcntl([_dataFile fileDescriptor], F_GETPATH, Path) != -1)
        //            NSLog(@"%@", [NSString stringWithUTF8String:Path]);
        //        if (_isVideoing == NO)
        [self sendBeaconDataToServer:strLine withID:beaconTimeStamp];
        
        [strLine appendString:@"\n"];
        [_dataFile seekToEndOfFile];
        [_dataFile writeData:[strLine dataUsingEncoding:NSUTF8StringEncoding]];
        _currentSmpNum++;
        _countDownLabel.text = [NSString stringWithFormat:@"%d", _currentSmpNum];
        

        
        if (_currentSmpNum == _targetSmpNum || !_isRecording) {
            [self disposeBeaconSampling];
        }
    }
}

- (void)startBeaconSampling {
    _currentSmpNum = 0;
    _targetSmpNum = 6000;
    _countDownLabel.text = [NSString stringWithFormat:@"%d", _currentSmpNum];
//    if (![_beaconFilterString isEqualToString:_beaconFilterTextView.text]) {
//        _beaconFilterString = _beaconFilterTextView.text;
//        _beaconMinors = [self analysisBeaconFilter:_beaconFilterString];
//    }

}

- (void)disposeBeaconSampling {
    
    NSLog(@"Dispose iBeacon Sampling.");
    _isSampling = false;
//    NSMutableString *strLine = [[NSMutableString alloc] init];
//    [strLine appendFormat:@"%.2f,%.2f\n", _xTextField.text.floatValue, _yTextField.text.floatValue];
//    [_dataFile seekToEndOfFile];
//    [_dataFile writeData:[strLine dataUsingEncoding:NSUTF8StringEncoding]];
    [_dataFile closeFile];
    _currentSmpNum = 0;
    
//    dispatch_async( dispatch_get_main_queue(), ^{
//    if (_xAutoMode == AutoInc) {
//        _xStepper.value = _xTextField.text.floatValue + 1;
//        _xTextField.text = [NSString stringWithFormat:@"%.1f", _xStepper.value];
//    } else if (_xAutoMode == AutoDec) {
//        _xStepper.value = _xTextField.text.floatValue - 1;
//        _xTextField.text = [NSString stringWithFormat:@"%.1f", _xStepper.value];
//    }
//    
//    if (_yAutoMode == AutoInc) {
//        _yStepper.value = _yTextField.text.floatValue + 1;
//        _yTextField.text = [NSString stringWithFormat:@"%.1f", _yStepper.value];
//    } else if (_yAutoMode == AutoDec){
//        _yStepper.value = _yTextField.text.floatValue - 1;
//        _yTextField.text = [NSString stringWithFormat:@"%.1f", _yStepper.value];
//    }
//    });
}

- (NSString *) timeStamp {
    return [NSString stringWithFormat:@"%.0f",[[NSDate date] timeIntervalSince1970] * 1000];
}

- (void)sendBeaconDataToServer: (NSMutableString *) beacon_data withID: (NSString*) timstamp
{
    if (beacon_data) {
    }
    
    NSMutableString* reqstr = [[NSMutableString alloc] init];;
    [reqstr appendString: @"http://54.213.246.151:5000/beacon?user=KKK&map=XXX&timestamp="];
    [reqstr appendString:timstamp];
    if (_isRecording) [reqstr appendString:@"&flg=1"];
    [reqstr appendString: @"&beacon="];//beacon
    [reqstr appendString:beacon_data];

//    NSLog(@"%@", [NSString stringWithString:reqstr]);
    
    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:[NSString stringWithString:reqstr]]];
    [request setHTTPMethod: @"GET"];
//    [request setValue:@"application/json;charset=UTF-8" forHTTPHeaderField:@"content-type"];
    
    NSURLSession *session = [NSURLSession sessionWithConfiguration:[NSURLSessionConfiguration defaultSessionConfiguration]];
    [[session dataTaskWithRequest:request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
//        NSString *request_reply = [[NSString alloc] initWithData:data encoding:NSASCIIStringEncoding];
//        NSLog(@"GET request response: %@", request_reply);
        
        if (data == nil) return;
        
        NSError *jsonError;
        id allKeys = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError];
        NSArray *estarr = [allKeys objectForKey:@"estimate"];
        NSString *sigid = [allKeys objectForKey:@"sigid"];
        NSString *flg = [allKeys objectForKey:@"flg"];
        
        NSLog(@"--- %@ --- BLE est = %@ %@ %@", sigid, estarr[0], estarr[1], estarr[2]);
        if ( flg == nil) {
            float estx = [estarr[0] floatValue], esty = [estarr[1] floatValue], estz = [estarr[2] floatValue];
            NSString* estCoordinates = [NSString stringWithFormat:@"x: %.2f y: %.2f z: %.2f", estx, esty, estz];
            dispatch_async( dispatch_get_main_queue(), ^{
                _estBeaconLabel.text = estCoordinates;
            });
            NSMutableString *strLine = [[NSMutableString alloc] init];
            [strLine appendString:timstamp];
            [strLine appendString:@"\t"];
            [strLine appendString:estCoordinates];
            [strLine appendString:@"\n"];
            
            [self recordImgEstimation:strLine to:@"/still_beacon_estPosition.txt"];
        }

    }] resume];
    
//    [request setHTTPMethod:@"GET"];
//    NSURLConnection *conn = [[NSURLConnection alloc] initWithRequest:request delegate:self];
//    [conn scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
//    [conn start];
    
//    NSLog(@"Sended image\n");
}

- (void)sendImageToServer: (NSData *) imageData withImageName:(NSString *)FileParam
{
    // the boundary string : a random string, that will not repeat in post data, to separate post data fields.
    NSString *BoundaryConstant = @"----------V2ymHFg03ehbqgZCaKO6jy";
    // string constant for the post parameter 'file'. My server uses this name: `file`. Your's may differ
//    NSString* FileParamConstant = FileParam;
    
    // Init the URLRequest
    NSMutableURLRequest *request = [[NSMutableURLRequest alloc] init];
    
    [request setURL:[NSURL URLWithString:@"http://54.213.246.151:5000/localize"]];
    [request setCachePolicy:NSURLRequestReloadIgnoringLocalCacheData];
//    [request setHTTPShouldHandleCookies:NO];
//    [request setTimeoutInterval:30];
    [request setHTTPMethod:@"POST"];
    
    // set Content-Type in HTTP header
    NSString *contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@", BoundaryConstant];
    [request setValue:contentType forHTTPHeaderField: @"Content-Type"];
    
    // post body
    NSMutableData *body = [NSMutableData data];
    
//    ------WebKitFormBoundary2oy19U9IREeZ5NNU Content-Disposition:
//    form-data; name="map" office
//    ------WebKitFormBoundary2oy19U9IREeZ5NNU Content-Disposition:
//    form-data; name="image"; filename="2015102200504917.jpg"
//    Content-Type: image/jpeg
//    ------WebKitFormBoundary2oy19U9IREeZ5NNU Content-Disposition:
//    form-data; name="user" 1
//    ------WebKitFormBoundary2oy19U9IREeZ5NNU--
    
    // add params (all params are strings)
    NSMutableDictionary* _params = [[NSMutableDictionary alloc] init];
    [_params setObject:@"test1" forKey:@"user"];
    [_params setObject:@"map0" forKey:@"map"];

    for (NSString *param in _params) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\n", BoundaryConstant] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", param] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"%@\r\n", [_params objectForKey:param]] dataUsingEncoding:NSUTF8StringEncoding]];
//        NSLog(@"%@, %@\n",param,[_params objectForKey:param]);
    }
    
    // add image data
    if (imageData) {
        [body appendData:[[NSString stringWithFormat:@"--%@\r\n", BoundaryConstant] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"image\"; filename=\"%@\"\r\n", FileParam] dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:[@"Content-Type: image/jpeg\r\n\r\n" dataUsingEncoding:NSUTF8StringEncoding]];
        [body appendData:imageData];
        [body appendData:[[NSString stringWithFormat:@"\r\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [body appendData:[[NSString stringWithFormat:@"--%@--\r\n", BoundaryConstant] dataUsingEncoding:NSUTF8StringEncoding]];


    
    [request setHTTPBody:body];
    // set the content-length
    NSString *postLength = [NSString stringWithFormat:@"%d", (int)[body length]];
    [request setValue:postLength forHTTPHeaderField:@"Content-Length"];
//    [request setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
    
    // Create url connection and fire request
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:request delegate:self];
    [connection scheduleInRunLoop:[NSRunLoop mainRunLoop] forMode:NSDefaultRunLoopMode];
    [connection start];
//    NSLog(@"Sended image\n");
    
    if (connection) {
        // response data of the request
    }
}

- (void)connection:(NSURLConnection *)connection didReceiveResponse:(NSURLResponse *)response {
    // A response has been received, this is where we initialize the instance var you created
    // so that we can append data to it in the didReceiveData method
    // Furthermore, this method is called each time there is a redirect so reinitializing it
    // also serves to clear it
}

// This method is used to receive the data which we get using post method.
- (void)connection:(NSURLConnection *)connection didReceiveData:(NSData*)data {
    NSString* rawEstCoordinates = [NSString stringWithUTF8String:[data bytes]];
//    NSLog(@"------%@", rawEstCoordinates);
    if (rawEstCoordinates == nil)
        return;
    
    NSError *jsonError;
    id allKeys = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonError]; //NSJSONWritingPrettyPrinted
//    for (int i = 0; i < [allKeys count]; i++) {}
    NSArray *estarr = [allKeys objectForKey:@"estimate"];
    NSString *imgid = [allKeys objectForKey:@"imageid"];
    NSLog(@"--- %@ --- est = %@ %@ %@", imgid, estarr[0], estarr[1], estarr[2]);
    float estx = [estarr[0] floatValue], esty = [estarr[1] floatValue], estz = [estarr[2] floatValue];
    NSString* estCoordinates = [NSString stringWithFormat:@"x: %.2f y: %.2f z: %.2f", estx, esty, estz];
    dispatch_async( dispatch_get_main_queue(), ^{
        _estLabel.text = estCoordinates;
    });
    NSMutableString *strLine = [[NSMutableString alloc] init];
    [strLine appendString:imgid];
    [strLine appendString:@"\t"];
    [strLine appendString:estCoordinates];
    [strLine appendString:@"\n"];
    
    [self recordImgEstimation:strLine to:@"/still_img_estPosition.txt"];
    
}

- (NSCachedURLResponse *)connection:(NSURLConnection *)connection willCacheResponse:(NSCachedURLResponse*)cachedResponse {
    // Return nil to indicate not necessary to store a cached response for this connection
    return nil;
}

// This method receives the error report in case of connection is not made to server.
- (void)connection:(NSURLConnection *)connection didFailWithError:(NSError *)error {
    NSLog(@"----- Error ----- %@\n", error);
}

// This method is used to process the data after connection has made successfully.
- (void)connectionDidFinishLoading:(NSURLConnection *)connection {

}

- (void)drawChart:(NSArray*) beacons {
    NSArray *vals = [NSArray arrayWithObjects:
                     [NSNumber numberWithInt:30],
                     [NSNumber numberWithInt:40],
                     [NSNumber numberWithInt:20],
                     [NSNumber numberWithInt:56],
                     [NSNumber numberWithInt:70],
                     [NSNumber numberWithInt:34],
                     [NSNumber numberWithInt:43],
                     nil];
    NSArray *refs = [NSArray arrayWithObjects:@"", @"Tu", @"W", @"Th", @"F", @"Sa", @"Su", nil];
//    DSBarChart *chrt = [[DSBarChart alloc] initWithFrame:_ChartView.bounds
//                                                   color:[UIColor whiteColor]
//                                              references:refs
//                                               andValues:vals];
//    chrt.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
//    chrt.bounds = _ChartView.bounds;
//    [_ChartView addSubview:chrt];
}

@end
