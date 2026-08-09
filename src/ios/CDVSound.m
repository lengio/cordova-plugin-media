/*
 Licensed to the Apache Software Foundation (ASF) under one
 or more contributor license agreements.  See the NOTICE file
 distributed with this work for additional information
 regarding copyright ownership.  The ASF licenses this file
 to you under the Apache License, Version 2.0 (the
 "License"); you may not use this file except in compliance
 with the License.  You may obtain a copy of the License at
 http://www.apache.org/licenses/LICENSE-2.0
 Unless required by applicable law or agreed to in writing,
 software distributed under the License is distributed on an
 "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
 KIND, either express or implied.  See the License for the
 specific language governing permissions and limitations
 under the License.
 */

#import "CDVSound.h"
#import <AVFoundation/AVFoundation.h>
#include <math.h>
#import "CDVFile.h"

#define DOCUMENTS_SCHEME_PREFIX @"documents://"
#define HTTP_SCHEME_PREFIX @"http://"
#define HTTPS_SCHEME_PREFIX @"https://"
#define CDVFILE_PREFIX @"cdvfile://"

#define CAPTURE_METADATA_SCHEMA_VERSION 2
#define ASSESSMENT_BIT_RATE_IN_BPS 64000
#define ASSESSMENT_CHANNEL_COUNT 1
#define ASSESSMENT_SAMPLE_RATE_IN_HZ 48000

/** The level reported for digital silence, in decibels relative to full scale */
#define SILENT_LEVEL_IN_DBFS -100.0f

@implementation CDVSound

BOOL keepAvAudioSessionAlwaysActive = NO;

// If YES, fall back to the old approach of using AVPlayer instead of AVAudioPlayer
#define FORCE_LEGACY_PLAYERS YES

@synthesize soundCache, avSession, currMediaId, statusCallbackId;

- (void)pluginInitialize
{
  self.soundOperationLock = [[NSLock alloc] init];

  [[NSNotificationCenter defaultCenter] addObserver:self
                                           selector:@selector(handleAudioSessionInterruption:)
                                               name:AVAudioSessionInterruptionNotification
                                             object:nil];

  NSDictionary *settings = self.commandDelegate.settings;
  keepAvAudioSessionAlwaysActive =
      [[settings objectForKey:[@"KeepAVAudioSessionAlwaysActive" lowercaseString]] boolValue];
  if (keepAvAudioSessionAlwaysActive) {
    if ([self hasAudioSession]) {
      NSError *error = nil;
      if (![self.avSession setActive:YES error:&error]) {
        NSLog(@"Unable to activate session: %@", [error localizedFailureReason]);
      }
    }
  }
}

/**
 * End a recording cleanly when the system takes the microphone away
 *
 * A call, an alarm or Siri interrupts the session without telling the web layer, which would
 * otherwise sit there showing a recording that stopped capturing. Stopping here runs the normal
 * finish path, so whatever was captured up to the interruption is still handed back.
 */
- (void)handleAudioSessionInterruption:(NSNotification *)notification
{
  NSNumber *type = notification.userInfo[AVAudioSessionInterruptionTypeKey];
  if (type.unsignedIntegerValue != AVAudioSessionInterruptionTypeBegan) {
    return;
  }

  // This arrives on whatever thread the system feels like, so it takes the same lock every command
  // does before going near the sound cache
  [self.soundOperationLock lock];

  for (NSString *mediaId in [[self soundCache] allKeys]) {
    CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];
    if (audioFile.recorder != nil && [audioFile.recorder isRecording]) {
      NSLog(@"Interrupted while recording audio sample '%@'", audioFile.resourcePath);
      [audioFile.recorder stop];
    }
  }

  [self.soundOperationLock unlock];
}

// Maps a url for a resource path for recording
- (NSURL *)urlForRecording:(NSString *)resourcePath
{
  NSURL *resourceURL = nil;
  NSString *filePath = nil;
  NSString *docsPath =
      NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];

  // first check for correct extension
  NSString *ext = [resourcePath pathExtension];
  if ([ext caseInsensitiveCompare:@"wav"] != NSOrderedSame &&
      [ext caseInsensitiveCompare:@"m4a"] != NSOrderedSame) {
    resourceURL = nil;
    NSLog(@"Resource for recording must have wav or m4a extension");
  } else if ([resourcePath hasPrefix:DOCUMENTS_SCHEME_PREFIX]) {
    // try to find Documents:// resources
    filePath = [resourcePath
        stringByReplacingOccurrencesOfString:DOCUMENTS_SCHEME_PREFIX
                                  withString:[NSString stringWithFormat:@"%@/", docsPath]];
    NSLog(@"Will use resource '%@' from the documents folder with path = %@", resourcePath,
          filePath);
  } else if ([resourcePath hasPrefix:CDVFILE_PREFIX]) {
    CDVFile *filePlugin = [self.commandDelegate getCommandInstance:@"File"];
    CDVFilesystemURL *url = [CDVFilesystemURL fileSystemURLWithString:resourcePath];
    filePath = [filePlugin filesystemPathForURL:url];
    if (filePath == nil) {
      resourceURL = [NSURL URLWithString:resourcePath];
    }
  } else {
    // if resourcePath is not from FileSystem put in tmp dir, else attempt to
    // use provided resource path
    NSString *tmpPath = [NSTemporaryDirectory() stringByStandardizingPath];
    BOOL isTmp = [resourcePath rangeOfString:tmpPath].location != NSNotFound;
    BOOL isDoc = [resourcePath rangeOfString:docsPath].location != NSNotFound;
    if (!isTmp && !isDoc) {
      // put in temp dir
      filePath = [NSString stringWithFormat:@"%@/%@", tmpPath, resourcePath];
    } else {
      filePath = resourcePath;
    }
  }

  if (filePath != nil) {
    // create resourceURL
    resourceURL = [NSURL fileURLWithPath:filePath];
  }
  return resourceURL;
}

// Maps a url for a resource path for playing
// "Naked" resource paths are assumed to be from the www folder as its base
- (NSURL *)urlForPlaying:(NSString *)resourcePath
{
  NSURL *resourceURL = nil;
  NSString *filePath = nil;

  // first try to find HTTP:// or Documents:// resources

  if ([resourcePath hasPrefix:HTTP_SCHEME_PREFIX] || [resourcePath hasPrefix:HTTPS_SCHEME_PREFIX]) {
    // if it is a http url, use it
    NSLog(@"Will use resource '%@' from the Internet.", resourcePath);
    resourceURL = [NSURL URLWithString:resourcePath];
  } else if ([resourcePath hasPrefix:DOCUMENTS_SCHEME_PREFIX]) {
    NSString *docsPath =
        NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES)[0];
    filePath = [resourcePath
        stringByReplacingOccurrencesOfString:DOCUMENTS_SCHEME_PREFIX
                                  withString:[NSString stringWithFormat:@"%@/", docsPath]];
    NSLog(@"Will use resource '%@' from the documents folder with path = %@", resourcePath,
          filePath);
  } else if ([resourcePath hasPrefix:CDVFILE_PREFIX]) {
    CDVFile *filePlugin = [self.commandDelegate getCommandInstance:@"File"];
    CDVFilesystemURL *url = [CDVFilesystemURL fileSystemURLWithString:resourcePath];
    filePath = [filePlugin filesystemPathForURL:url];
    if (filePath == nil) {
      resourceURL = [NSURL URLWithString:resourcePath];
    }
  } else {
    // attempt to find file path in www directory or LocalFileSystem.TEMPORARY
    // directory
    filePath = [self.commandDelegate pathForResource:resourcePath];
    if (filePath == nil) {
      // see if this exists in the documents/temp directory from a previous
      // recording
      NSString *testPath =
          [NSString stringWithFormat:@"%@/%@", [NSTemporaryDirectory() stringByStandardizingPath],
                                     resourcePath];
      if ([[NSFileManager defaultManager] fileExistsAtPath:testPath]) {
        // inefficient as existence will be checked again below but only way to
        // determine if file exists from previous recording
        filePath = testPath;
        NSLog(@"Will attempt to use file resource from "
              @"LocalFileSystem.TEMPORARY directory");
      } else {
        // attempt to use path provided
        filePath = resourcePath;
        NSLog(@"Will attempt to use file resource '%@'", filePath);
      }
    } else {
      NSLog(@"Found resource '%@' in the web folder.", filePath);
    }
  }
  // if the resourcePath resolved to a file path, check that file exists
  if (filePath != nil) {
    // create resourceURL
    resourceURL = [NSURL fileURLWithPath:filePath];
    // try to access file
    NSFileManager *fMgr = [NSFileManager defaultManager];
    if (![fMgr fileExistsAtPath:filePath]) {
      resourceURL = nil;
      NSLog(@"Unknown resource '%@'", resourcePath);
    }
  }

  return resourceURL;
}

// Creates or gets the cached audio file resource object
- (CDVAudioFile *)audioFileForResource:(NSString *)resourcePath
                                withId:(NSString *)mediaId
                          doValidation:(BOOL)bValidate
                          forRecording:(BOOL)bRecord
              suppressValidationErrors:(BOOL)bSuppress
{
  BOOL bError = NO;
  CDVMediaError errcode = MEDIA_ERR_NONE_SUPPORTED;
  NSString *errMsg = @"";
  CDVAudioFile *audioFile = nil;
  NSURL *resourceURL = nil;

  if ([self soundCache] == nil) {
    [self setSoundCache:[NSMutableDictionary dictionaryWithCapacity:1]];
  } else {
    audioFile = [[self soundCache] objectForKey:mediaId];
  }
  if (audioFile == nil) {
    // validate resourcePath and create
    if ((resourcePath == nil) || ![resourcePath isKindOfClass:[NSString class]] ||
        [resourcePath isEqualToString:@""]) {
      bError = YES;
      errcode = MEDIA_ERR_ABORTED;
      errMsg = @"invalid media src argument";
    } else {
      audioFile = [[CDVAudioFile alloc] init];
      audioFile.resourcePath = resourcePath;
      audioFile.resourceURL = nil; // validate resourceURL when actually play or record
      [[self soundCache] setObject:audioFile forKey:mediaId];
    }
  }
  if (bValidate && (audioFile.resourceURL == nil)) {
    if (bRecord) {
      resourceURL = [self urlForRecording:resourcePath];
    } else {
      resourceURL = [self urlForPlaying:resourcePath];
    }
    if ((resourceURL == nil) && !bSuppress) {
      bError = YES;
      errcode = MEDIA_ERR_ABORTED;
      errMsg =
          [NSString stringWithFormat:@"Cannot use audio file from resource '%@'", resourcePath];
    } else {
      audioFile.resourceURL = resourceURL;
    }
  }

  if (bError) {
    [self onStatus:MEDIA_ERROR
           mediaId:mediaId
             param:[self createMediaErrorWithCode:errcode message:errMsg]];
  }

  return audioFile;
}

// Creates or gets the cached audio file resource object
- (CDVAudioFile *)audioFileForResource:(NSString *)resourcePath
                                withId:(NSString *)mediaId
                          doValidation:(BOOL)bValidate
                          forRecording:(BOOL)bRecord
{
  return [self audioFileForResource:resourcePath
                             withId:mediaId
                       doValidation:bValidate
                       forRecording:bRecord
           suppressValidationErrors:NO];
}

// returns whether or not audioSession is available - creates it if necessary
- (BOOL)hasAudioSession
{
  BOOL bSession = YES;

  if (!self.avSession) {
    NSError *error = nil;

    self.avSession = [AVAudioSession sharedInstance];
    if (error) {
      // is not fatal if can't get AVAudioSession , just log the error
      NSLog(@"error creating audio session: %@", [[error userInfo] description]);
      self.avSession = nil;
      bSession = NO;
    }
  }
  return bSession;
}

// helper function to create a error object string
- (NSDictionary *)createMediaErrorWithCode:(CDVMediaError)code message:(NSString *)message
{
  NSMutableDictionary *errorDict = [NSMutableDictionary dictionaryWithCapacity:2];

  [errorDict setObject:[NSNumber numberWithUnsignedInteger:code] forKey:@"code"];
  [errorDict setObject:message ? message : @"" forKey:@"message"];
  return errorDict;
}

// helper function to create specifically an abort error
- (NSDictionary *)createAbortError:(NSString *)message
{
  return [self createMediaErrorWithCode:MEDIA_ERR_ABORTED message:message];
}

- (void)create:(CDVInvokedUrlCommand *)command
{
  NSString *mediaId = [command argumentAtIndex:0];
  NSString *resourcePath = [command argumentAtIndex:1];

  CDVAudioFile *audioFile = [self audioFileForResource:resourcePath
                                                withId:mediaId
                                          doValidation:YES
                                          forRecording:NO
                              suppressValidationErrors:YES];

  if (audioFile == nil) {
    NSString *errorMessage =
        [NSString stringWithFormat:@"Failed to initialize Media file with path %@", resourcePath];
    [self onStatus:MEDIA_ERROR mediaId:mediaId param:[self createAbortError:errorMessage]];
  } else {
    NSURL *resourceUrl = audioFile.resourceURL;

    if (![resourceUrl isFileURL] && ![resourcePath hasPrefix:CDVFILE_PREFIX] &&
        !FORCE_LEGACY_PLAYERS) {
      // First create an AVPlayerItem
      AVPlayerItem *playerItem = [AVPlayerItem playerItemWithURL:resourceUrl];

      // Subscribe to the AVPlayerItem's DidPlayToEndTime notification.
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(itemDidFinishPlaying:)
                                                   name:AVPlayerItemDidPlayToEndTimeNotification
                                                 object:playerItem];

      // Subscribe to the AVPlayerItem's PlaybackStalledNotification
      // notification.
      [[NSNotificationCenter defaultCenter] addObserver:self
                                               selector:@selector(itemStalledPlaying:)
                                                   name:AVPlayerItemPlaybackStalledNotification
                                                 object:playerItem];

      // Pass the AVPlayerItem to a new player
      avPlayer = [[AVPlayer alloc] initWithPlayerItem:playerItem];

      // Avoid excessive buffering so streaming media can play instantly on iOS
      // Removes preplay delay on ios 10+, makes consistent with ios9 behaviour
      if ([NSProcessInfo.processInfo
              isOperatingSystemAtLeastVersion:(NSOperatingSystemVersion){10, 0, 0}]) {
        avPlayer.automaticallyWaitsToMinimizeStalling = NO;
      }
    }

    self.currMediaId = mediaId;

    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK];
    [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
  }
}

- (void)setVolume:(CDVInvokedUrlCommand *)command
{
  NSString *callbackId = command.callbackId;
#pragma unused(callbackId)

  NSString *mediaId = [command argumentAtIndex:0];
  NSNumber *volume = [command argumentAtIndex:1 withDefault:[NSNumber numberWithFloat:1.0]];

  if ([self soundCache] != nil) {
    CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];
    if (audioFile != nil) {
      audioFile.volume = volume;
      if (audioFile.player) {
        audioFile.player.volume = [volume floatValue];
      } else {
        float customVolume = [volume floatValue];
        if (customVolume >= 0.0 && customVolume <= 1.0) {
          [avPlayer setVolume:customVolume];
        } else {
          NSLog(@"The value must be within the range of 0.0 to 1.0");
        }
      }
      [[self soundCache] setObject:audioFile forKey:mediaId];
    }
  }

  // don't care for any callbacks
}

- (void)setRate:(CDVInvokedUrlCommand *)command
{
  NSString *callbackId = command.callbackId;
#pragma unused(callbackId)

  NSString *mediaId = [command argumentAtIndex:0];
  NSNumber *rate = [command argumentAtIndex:1 withDefault:[NSNumber numberWithFloat:1.0]];

  if ([self soundCache] != nil) {
    CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];
    if (audioFile != nil) {
      audioFile.rate = rate;
      if (audioFile.player) {
        audioFile.player.enableRate = YES;
        audioFile.player.rate = [rate floatValue];
      }
      if (avPlayer.currentItem && avPlayer.currentItem.asset) {
        float customRate = [rate floatValue];
        [avPlayer setRate:customRate];
      }

      [[self soundCache] setObject:audioFile forKey:mediaId];
    }
  }

  // don't care for any callbacks
}

- (void)startPlayingAudio:(CDVInvokedUrlCommand *)command
{
  [self.commandDelegate runInBackground:^{
    [self.soundOperationLock lock];
    NSString *callbackId = command.callbackId;
#pragma unused(callbackId)

    NSString *mediaId = [command argumentAtIndex:0];
    NSString *resourcePath = [command argumentAtIndex:1];
    NSDictionary *options = [command argumentAtIndex:2 withDefault:nil];

    BOOL bError = NO;

    CDVAudioFile *audioFile = [self audioFileForResource:resourcePath
                                                  withId:mediaId
                                            doValidation:YES
                                            forRecording:NO];
    if ((audioFile != nil) && (audioFile.resourceURL != nil)) {
      if (audioFile.player == nil) {
        bError = [self prepareToPlay:audioFile withId:mediaId];
      }
      if (!bError) {
        // self.currMediaId = audioFile.player.mediaId;
        self.currMediaId = mediaId;

        // audioFile.player != nil  or player was successfully created
        // get the audioSession and set the category to allow Playing when
        // device is locked or ring/silent switch engaged
        if ([self hasAudioSession]) {
          NSError *__autoreleasing err = nil;
          NSNumber *playAudioWhenScreenIsLocked =
              [options objectForKey:@"playAudioWhenScreenIsLocked"];
          BOOL bPlayAudioWhenScreenIsLocked = YES;
          if (playAudioWhenScreenIsLocked != nil) {
            bPlayAudioWhenScreenIsLocked = [playAudioWhenScreenIsLocked boolValue];
          }

          NSString *sessionCategory = bPlayAudioWhenScreenIsLocked
                                          ? AVAudioSessionCategoryPlayback
                                          : AVAudioSessionCategorySoloAmbient;
          [self.avSession setMode:AVAudioSessionModeDefault error:&err];
          [self.avSession setCategory:sessionCategory error:&err];
          if (![self.avSession setActive:YES error:&err]) {
            // other audio with higher priority that does not allow mixing could
            // cause this to fail
            NSLog(@"Unable to play audio: %@", [err localizedFailureReason]);
            bError = YES;
          }
        }
        if (!bError) {
          NSLog(@"Playing audio sample '%@'", audioFile.resourcePath);
          double duration = 0;
          if (avPlayer.currentItem && avPlayer.currentItem.asset) {
            CMTime time = avPlayer.currentItem.asset.duration;
            duration = CMTimeGetSeconds(time);
            if (isnan(duration)) {
              NSLog(@"Duration is infifnite, setting it to -1");
              duration = -1;
            }

            if (audioFile.rate != nil) {
              float customRate = [audioFile.rate floatValue];
              NSLog(@"Playing stream with AVPlayer & custom rate");
              [avPlayer setRate:customRate];
            } else {
              NSLog(@"Playing stream with AVPlayer & default rate");
              [avPlayer play];
            }

          } else {
            NSNumber *loopOption = [options objectForKey:@"numberOfLoops"];
            NSInteger numberOfLoops = 0;
            if (loopOption != nil) {
              numberOfLoops = [loopOption intValue] - 1;
            }
            audioFile.player.numberOfLoops = numberOfLoops;
            if (audioFile.player.isPlaying) {
              [audioFile.player stop];
              audioFile.player.currentTime = 0;
            }
            if (audioFile.volume != nil) {
              audioFile.player.volume = [audioFile.volume floatValue];
            }

            audioFile.player.enableRate = YES;
            if (audioFile.rate != nil) {
              audioFile.player.rate = [audioFile.rate floatValue];
            }

            [audioFile.player play];
            duration = round(audioFile.player.duration * 1000) / 1000;
          }

          [self onStatus:MEDIA_DURATION mediaId:mediaId param:@(duration)];
          [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_RUNNING)];
        }
      }
      if (bError) {
        /*  I don't see a problem playing previously recorded audio so removing
        this section - BG NSError* error;
        // try loading it one more time, in case the file was recorded
        previously audioFile.player = [[ AVAudioPlayer alloc ]
        initWithContentsOfURL:audioFile.resourceURL error:&error]; if (error !=
        nil) { NSLog(@"Failed to initialize AVAudioPlayer: %@\n", error);
            audioFile.player = nil;
        } else {
            NSLog(@"Playing audio sample '%@'", audioFile.resourcePath);
            audioFile.player.numberOfLoops = numberOfLoops;
            [audioFile.player play];
        } */
        // error creating the session or player
        [self onStatus:MEDIA_ERROR
               mediaId:mediaId
                 param:[self createMediaErrorWithCode:MEDIA_ERR_NONE_SUPPORTED message:nil]];
      }
    }

    [self.soundOperationLock unlock];
    // else audioFile was nil - error already returned from audioFile for
    // resource
    return;
  }];
}

- (BOOL)prepareToPlay:(CDVAudioFile *)audioFile withId:(NSString *)mediaId
{
  BOOL bError = NO;
  NSError *__autoreleasing playerError = nil;

  // create the player
  NSURL *resourceURL = audioFile.resourceURL;

  if ([resourceURL isFileURL]) {
    audioFile.player = [[CDVAudioPlayer alloc] initWithContentsOfURL:resourceURL
                                                               error:&playerError];
  } else {
    if (FORCE_LEGACY_PLAYERS) {
      NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:resourceURL];
      NSURLResponse *__autoreleasing response = nil;
      NSData *data = [NSURLConnection sendSynchronousRequest:request
                                           returningResponse:&response
                                                       error:&playerError];
      if (playerError) {
        NSLog(@"Unable to download audio from: %@", [resourceURL absoluteString]);
      } else {
        // bug in AVAudioPlayer when playing downloaded data in NSData - we have to download the
        // file and play from disk
        CFUUIDRef uuidRef = CFUUIDCreate(kCFAllocatorDefault);
        CFStringRef uuidString = CFUUIDCreateString(kCFAllocatorDefault, uuidRef);
        NSString *filePath =
            [NSString stringWithFormat:@"%@/%@", [NSTemporaryDirectory() stringByStandardizingPath],
                                       uuidString];
        CFRelease(uuidString);
        CFRelease(uuidRef);
        [data writeToFile:filePath atomically:YES];
        NSURL *fileURL = [NSURL fileURLWithPath:filePath];
        audioFile.player = [[CDVAudioPlayer alloc] initWithContentsOfURL:fileURL
                                                                   error:&playerError];
      }
    }
  }

  if (playerError != nil) {
    NSLog(@"Failed to initialize AVAudioPlayer: %@\n", [playerError localizedDescription]);
    audioFile.player = nil;
    if (!keepAvAudioSessionAlwaysActive && self.avSession && ![self isPlayingOrRecording]) {
      [self.avSession setActive:NO error:nil];
    }
    bError = YES;
  } else {
    audioFile.player.mediaId = mediaId;
    audioFile.player.delegate = self;
    if (avPlayer == nil)
      bError = ![audioFile.player prepareToPlay];
  }
  return bError;
}

- (void)stopPlayingAudio:(CDVInvokedUrlCommand *)command
{
  [self.soundOperationLock lock];
  NSString *mediaId = [command argumentAtIndex:0];
  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];

  if ((audioFile != nil) && (audioFile.player != nil)) {
    NSLog(@"Stopped playing audio sample '%@'", audioFile.resourcePath);
    [audioFile.player stop];
    audioFile.player.currentTime = 0;
    [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
  }
  // seek to start and pause
  if (avPlayer.currentItem && avPlayer.currentItem.asset) {
    BOOL isReadyToSeek = (avPlayer.status == AVPlayerStatusReadyToPlay) &&
                         (avPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay);
    if (isReadyToSeek) {
      [avPlayer seekToTime:kCMTimeZero
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero
          completionHandler:^(BOOL finished) {
            if (finished)
              [avPlayer pause];
          }];
      [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
    } else {
      // cannot seek, wrong state
      CDVMediaError errcode = MEDIA_ERR_NONE_ACTIVE;
      NSString *errMsg = @"Cannot service stop request until the avPlayer is "
                         @"in 'AVPlayerStatusReadyToPlay' state.";
      [self onStatus:MEDIA_ERROR
             mediaId:mediaId
               param:[self createMediaErrorWithCode:errcode message:errMsg]];
    }
  }
  [self.soundOperationLock unlock];
}

- (void)pausePlayingAudio:(CDVInvokedUrlCommand *)command
{
  NSString *mediaId = [command argumentAtIndex:0];
  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];

  if ((audioFile != nil) && ((audioFile.player != nil) || (avPlayer != nil))) {
    NSLog(@"Paused playing audio sample '%@'", audioFile.resourcePath);
    if (audioFile.player != nil) {
      [audioFile.player pause];
    } else if (avPlayer != nil) {
      [avPlayer pause];
    }

    [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_PAUSED)];
  }
}

- (void)seekToAudio:(CDVInvokedUrlCommand *)command
{
  [self.soundOperationLock lock];
  // args:
  // 0 = Media id
  // 1 = seek to location in milliseconds

  NSString *mediaId = [command argumentAtIndex:0];

  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];
  double position = [[command argumentAtIndex:1] doubleValue];
  double posInSeconds = position / 1000;

  if ((audioFile != nil) && (audioFile.player != nil)) {
    if (posInSeconds >= audioFile.player.duration) {
      // The seek is past the end of file.  Stop media and reset to beginning
      // instead of seeking past the end.
      [audioFile.player stop];
      audioFile.player.currentTime = 0;
      [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
    } else {
      audioFile.player.currentTime = posInSeconds;
      [self onStatus:MEDIA_POSITION mediaId:mediaId param:@(posInSeconds)];
    }

  } else if (avPlayer != nil) {
    int32_t timeScale = avPlayer.currentItem.asset.duration.timescale;
    CMTime timeToSeek = CMTimeMakeWithSeconds(posInSeconds, timeScale);

    BOOL isPlaying = (avPlayer.rate > 0 && !avPlayer.error);
    BOOL isReadyToSeek = (avPlayer.status == AVPlayerStatusReadyToPlay) &&
                         (avPlayer.currentItem.status == AVPlayerItemStatusReadyToPlay);
    float currentPlaybackRate = avPlayer.rate;

    // CB-10535:
    // When dealing with remote files, we can get into a situation where we
    // start playing before AVPlayer has had the time to buffer the file to be
    // played. To avoid the app crashing in such a situation, we only seek if
    // both the player and the player item are ready to play. If not ready, we
    // send an error back to JS land.
    if (isReadyToSeek) {
      [avPlayer seekToTime:timeToSeek
            toleranceBefore:kCMTimeZero
             toleranceAfter:kCMTimeZero
          completionHandler:^(BOOL finished) {
            if (isPlaying) {
              [avPlayer play];
              // [avPlayer play] sets the rate to 1, so we need to set it again
              // after seeking
              [avPlayer setRate:currentPlaybackRate];
            };
          }];
    } else {
      NSString *errMsg = @"AVPlayerItem cannot service a seek request with a completion "
                         @"handler until its status is AVPlayerItemStatusReadyToPlay.";
      [self onStatus:MEDIA_ERROR mediaId:mediaId param:[self createAbortError:errMsg]];
    }
  }
  [self.soundOperationLock unlock];
}

- (void)release:(CDVInvokedUrlCommand *)command
{
  [self.soundOperationLock lock];
  NSString *mediaId = [command argumentAtIndex:0];
  // NSString* mediaId = self.currMediaId;

  if (mediaId != nil) {
    CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];

    if (audioFile != nil) {
      if (audioFile.player && [audioFile.player isPlaying]) {
        [audioFile.player stop];
      }
      if (audioFile.recorder && [audioFile.recorder isRecording]) {
        [audioFile.recorder stop];
      }
      if (avPlayer != nil) {
        [avPlayer pause];
        avPlayer = nil;
      }
      if (!keepAvAudioSessionAlwaysActive && self.avSession && ![self isPlayingOrRecording]) {
        [self.avSession setActive:NO error:nil];
        self.avSession = nil;
      }
      [[self soundCache] removeObjectForKey:mediaId];
      NSLog(@"Media with id %@ released", mediaId);
    }
  }
  [self.soundOperationLock unlock];
}

- (void)getCurrentPositionAudio:(CDVInvokedUrlCommand *)command
{
  NSString *callbackId = command.callbackId;
  NSString *mediaId = [command argumentAtIndex:0];
#pragma unused(mediaId)

  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];
  double position = -1;

  if ((audioFile != nil) && (audioFile.player != nil) && [audioFile.player isPlaying]) {
    position = round(audioFile.player.currentTime * 1000) / 1000;
  }
  if (avPlayer) {
    CMTime time = [avPlayer currentTime];
    position = CMTimeGetSeconds(time);
  }

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                              messageAsDouble:position];

  [self onStatus:MEDIA_POSITION mediaId:mediaId param:@(position)];
  [self.commandDelegate sendPluginResult:result callbackId:callbackId];
}

- (void)startRecordingAudio:(CDVInvokedUrlCommand *)command
{
  [self.soundOperationLock lock];
  NSString *callbackId = command.callbackId;
#pragma unused(callbackId)

  NSString *mediaId = [command argumentAtIndex:0];
  CDVAudioFile *audioFile = [self audioFileForResource:[command argumentAtIndex:1]
                                                withId:mediaId
                                          doValidation:YES
                                          forRecording:YES];
  __block NSString *errorMsg = @"";

  if ((audioFile != nil) && (audioFile.resourceURL != nil)) {
    __weak CDVSound *weakSelf = self;

    void (^startRecording)(void) = ^{
      NSError *__autoreleasing error = nil;

      // A recorder left ready by `prepareRecordingAudio` is exactly what we want; anything else
      // is stale and gets rebuilt below.
      if (audioFile.recorder != nil && !audioFile.recorderPrepared) {
        [audioFile.recorder stop];
        audioFile.recorder = nil;
      }
      // get the audioSession and set the category to allow recording when
      // device is locked or ring/silent switch engaged
      if ([weakSelf hasAudioSession]) {
        if (![weakSelf.avSession.category isEqualToString:AVAudioSessionCategoryPlayAndRecord]) {
          [weakSelf.avSession setCategory:AVAudioSessionCategoryRecord error:nil];
        }

        NSError *sessionError = nil;
        if (![weakSelf.avSession setMode:AVAudioSessionModeMeasurement error:&sessionError]) {
          NSLog(@"Unable to enable measurement mode: %@", [sessionError localizedFailureReason]);
        }
        sessionError = nil;
        if (![weakSelf.avSession setPreferredSampleRate:ASSESSMENT_SAMPLE_RATE_IN_HZ
                                                  error:&sessionError]) {
          NSLog(@"Unable to set preferred recording sample rate: %@",
                [sessionError localizedFailureReason]);
        }

        if (![weakSelf.avSession setActive:YES error:&error]) {
          // other audio with higher priority that does not allow mixing could
          // cause this to fail
          errorMsg = [NSString
              stringWithFormat:@"Unable to record audio: %@", [error localizedFailureReason]];
          [weakSelf onStatus:MEDIA_ERROR mediaId:mediaId param:[self createAbortError:errorMsg]];
          return;
        }
      }

      bool isWav = [[audioFile.resourcePath pathExtension] isEqualToString:@"wav"];
      if (audioFile.recorder == nil) {
        [weakSelf buildRecorderFor:audioFile withId:mediaId isWav:isWav error:&error];
      }

      bool recordingSuccess = NO;
      if (error == nil && audioFile.recorder != nil) {
        recordingSuccess = [audioFile.recorder record];

        // A recorder readied before the session was configured for recording could in principle be
        // refused once it is; rebuilding costs a moment but beats failing the user's recording.
        if (!recordingSuccess && audioFile.recorderPrepared) {
          NSLog(@"Prepared recorder refused to start; rebuilding");
          [weakSelf buildRecorderFor:audioFile withId:mediaId isWav:isWav error:&error];
          recordingSuccess = (error == nil) && [audioFile.recorder record];
        }

        audioFile.recorderPrepared = NO;
        if (recordingSuccess) {
          NSLog(@"Started recording audio sample '%@'", audioFile.resourcePath);
          audioFile.recordingMetadata = [weakSelf buildRecordingMetadata:audioFile isWav:isWav];
          [weakSelf onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_RUNNING)];
        }
      }

      if ((error != nil) || (recordingSuccess == NO)) {
        if (error != nil) {
          errorMsg = [NSString stringWithFormat:@"Failed to initialize AVAudioRecorder: %@\n",
                                                [error localizedFailureReason]];
        } else {
          errorMsg = @"Failed to start recording using AVAudioRecorder";
        }
        audioFile.recorder = nil;
        if (!keepAvAudioSessionAlwaysActive && weakSelf.avSession && ![self isPlayingOrRecording]) {
          [weakSelf.avSession setActive:NO error:nil];
        }
        [weakSelf onStatus:MEDIA_ERROR mediaId:mediaId param:[self createAbortError:errorMsg]];
      }
    };

    SEL rrpSel = NSSelectorFromString(@"requestRecordPermission:");
    if ([self hasAudioSession] && [self.avSession respondsToSelector:rrpSel]) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
      [self.avSession performSelector:rrpSel
                           withObject:^(BOOL granted) {
                             if (granted) {
                               startRecording();
                             } else {
                               NSString *msg = @"Error creating audio session, microphone "
                                               @"permission denied.";
                               NSLog(@"%@", msg);
                               audioFile.recorder = nil;
                               if (!keepAvAudioSessionAlwaysActive && weakSelf.avSession &&
                                   ![self isPlayingOrRecording]) {
                                 [weakSelf.avSession setActive:NO error:nil];
                               }
                               [weakSelf onStatus:MEDIA_ERROR
                                          mediaId:mediaId
                                            param:[self createAbortError:msg]];
                             }
                           }];
#pragma clang diagnostic pop
    } else {
      startRecording();
    }

  } else {
    // file did not validate
    NSString *errorMsg =
        [NSString stringWithFormat:@"Could not record audio at '%@'", audioFile.resourcePath];
    [self onStatus:MEDIA_ERROR mediaId:mediaId param:[self createAbortError:errorMsg]];
  }
  [self.soundOperationLock unlock];
}

- (void)stopRecordingAudio:(CDVInvokedUrlCommand *)command
{
  [self.soundOperationLock lock];
  NSString *mediaId = [command argumentAtIndex:0];

  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];

  if ((audioFile != nil) && (audioFile.recorder != nil)) {
    NSLog(@"Stopped recording audio sample '%@'", audioFile.resourcePath);
    [audioFile.recorder stop];
    // no callback - that will happen in audioRecorderDidFinishRecording
  }
  [self.soundOperationLock unlock];
}

- (void)audioRecorderDidFinishRecording:(AVAudioRecorder *)recorder successfully:(BOOL)flag
{
  CDVAudioRecorder *aRecorder = (CDVAudioRecorder *)recorder;
  NSString *mediaId = aRecorder.mediaId;
  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];

  if (audioFile != nil) {
    NSLog(@"Finished recording audio sample '%@'", audioFile.resourcePath);
  }
  // Recording puts the session into measurement mode, which also strips the processing from
  // playback and can move it off the speaker. Hand the session back the way we found it.
  if (self.avSession && ![self isPlayingOrRecording]) {
    [self.avSession setMode:AVAudioSessionModeDefault error:nil];
  }

  if (flag) {
    [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
  } else {
    [self onStatus:MEDIA_ERROR
           mediaId:mediaId
             param:[self createMediaErrorWithCode:MEDIA_ERR_DECODE message:nil]];
  }
  if (!keepAvAudioSessionAlwaysActive && self.avSession && ![self isPlayingOrRecording]) {
    [self.avSession setActive:NO error:nil];
  }
}

- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player successfully:(BOOL)flag
{
  // commented as unused
  CDVAudioPlayer *aPlayer = (CDVAudioPlayer *)player;
  NSString *mediaId = aPlayer.mediaId;
  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];

  if (audioFile != nil) {
    NSLog(@"Finished playing audio sample '%@'", audioFile.resourcePath);
  }
  if (flag) {
    audioFile.player.currentTime = 0;
    [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
  } else {
    [self onStatus:MEDIA_ERROR
           mediaId:mediaId
             param:[self createMediaErrorWithCode:MEDIA_ERR_DECODE message:nil]];
  }
  if (!keepAvAudioSessionAlwaysActive && self.avSession && ![self isPlayingOrRecording]) {
    [self.avSession setActive:NO error:nil];
  }
}

- (void)itemDidFinishPlaying:(NSNotification *)notification
{
  // Will be called when AVPlayer finishes playing playerItem
  NSString *mediaId = self.currMediaId;

  if (!keepAvAudioSessionAlwaysActive && self.avSession && ![self isPlayingOrRecording]) {
    [self.avSession setActive:NO error:nil];
  }
  [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_STOPPED)];
}

- (void)itemStalledPlaying:(NSNotification *)notification
{
  // Will be called when playback stalls due to buffer empty
  NSLog(@"Stalled playback");
  NSString* errMsg = @"stalled_playback";
  NSString* mediaId = self.currMediaId;
  [self onStatus:MEDIA_ERROR mediaId:mediaId param:[self createAbortError:errMsg]];
}

- (void)onMemoryWarning
{
  [self.soundOperationLock lock];
  /* https://issues.apache.org/jira/browse/CB-11513 */
  NSMutableArray *keysToRemove = [[NSMutableArray alloc] init];

  for (id key in [self soundCache]) {
    CDVAudioFile *audioFile = [[self soundCache] objectForKey:key];
    if (audioFile != nil) {
      if (audioFile.player != nil && ![audioFile.player isPlaying]) {
        [keysToRemove addObject:key];
      }
      if (audioFile.recorder != nil && ![audioFile.recorder isRecording]) {
        [keysToRemove addObject:key];
      }
    }
  }

  [[self soundCache] removeObjectsForKeys:keysToRemove];

  // [[self soundCache] removeAllObjects];
  // [self setSoundCache:nil];
  [self setAvSession:nil];

  [super onMemoryWarning];
  [self.soundOperationLock unlock];
}

- (void)dealloc
{
  [[self soundCache] removeAllObjects];
}

- (void)onReset
{
  [self.soundOperationLock lock];
  for (CDVAudioFile *audioFile in [[self soundCache] allValues]) {
    if (audioFile != nil) {
      if (audioFile.player != nil) {
        [audioFile.player stop];
        audioFile.player.currentTime = 0;
      }
      if (audioFile.recorder != nil) {
        [audioFile.recorder stop];
      }
    }
  }

  [[self soundCache] removeAllObjects];
  [self.soundOperationLock unlock];
}

- (void)getCurrentAmplitudeAudio:(CDVInvokedUrlCommand *)command
{
  [self.soundOperationLock lock];
  NSString *callbackId = command.callbackId;
  NSString *mediaId = [command argumentAtIndex:0];
#pragma unused(mediaId)

  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];
  float amplitude = 0; // The linear 0.0 .. 1.0 value

  if ((audioFile != nil) && (audioFile.recorder != nil) && [audioFile.recorder isRecording]) {
    [audioFile.recorder updateMeters];
    float minDecibels = -60.0f; // Or use -60dB, which I measured in a silent room.
    float decibels = [audioFile.recorder averagePowerForChannel:0];
    if (decibels < minDecibels) {
      amplitude = 0.0f;
    } else if (decibels >= 0.0f) {
      amplitude = 1.0f;
    } else {
      float root = 2.0f;
      float minAmp = powf(10.0f, 0.05f * minDecibels);
      float inverseAmpRange = 1.0f / (1.0f - minAmp);
      float amp = powf(10.0f, 0.05f * decibels);
      float adjAmp = (amp - minAmp) * inverseAmpRange;
      amplitude = powf(adjAmp, 1.0f / root);
    }
  }
  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                              messageAsDouble:amplitude];
  [self.commandDelegate sendPluginResult:result callbackId:callbackId];
  [self.soundOperationLock unlock];
}

/** Create the recorder for an audio file and get it ready to capture */
- (void)buildRecorderFor:(CDVAudioFile *)audioFile
                  withId:(NSString *)mediaId
                   isWav:(bool)isWav
                   error:(NSError *__autoreleasing *)error
{
  NSMutableDictionary *audioSettings = [NSMutableDictionary dictionaryWithDictionary:@{
    AVSampleRateKey : @(ASSESSMENT_SAMPLE_RATE_IN_HZ),
    AVNumberOfChannelsKey : @(ASSESSMENT_CHANNEL_COUNT),
  }];
  if (isWav) {
    audioSettings[AVFormatIDKey] = @(kAudioFormatLinearPCM);
    audioSettings[AVLinearPCMBitDepthKey] = @(16);
    audioSettings[AVLinearPCMIsBigEndianKey] = @(false);
    audioSettings[AVLinearPCMIsFloatKey] = @(false);
  } else {
    audioSettings[AVFormatIDKey] = @(kAudioFormatMPEG4AAC);
    audioSettings[AVEncoderAudioQualityKey] = @(AVAudioQualityHigh);
    audioSettings[AVEncoderBitRateKey] = @(ASSESSMENT_BIT_RATE_IN_BPS);
  }

  audioFile.recordingMetadata = nil;
  audioFile.recorderPrepared = NO;
  audioFile.recorder = [[CDVAudioRecorder alloc] initWithURL:audioFile.resourceURL
                                                    settings:audioSettings
                                                       error:error];
  if (*error != nil) {
    audioFile.recorder = nil;
    return;
  }

  audioFile.recorder.delegate = self;
  audioFile.recorder.mediaId = mediaId;
  audioFile.recorder.meteringEnabled = YES;
}

/**
 * Build the recorder and let it allocate its file and buffers, without recording
 *
 * This deliberately leaves the audio session alone. Activating a recording session is the part
 * that takes the audio route away from anything else that's playing and lights the system's
 * in-use indicator, so that stays on the user's actual tap; only the work that costs time without
 * touching the microphone moves here.
 */
- (void)prepareRecordingAudio:(CDVInvokedUrlCommand *)command
{
  [self.soundOperationLock lock];

  NSString *mediaId = [command argumentAtIndex:0];
  CDVAudioFile *audioFile = [self audioFileForResource:[command argumentAtIndex:1]
                                                withId:mediaId
                                          doValidation:YES
                                          forRecording:YES];

  if ((audioFile != nil) && (audioFile.resourceURL != nil) && (audioFile.recorder == nil)) {
    NSError *__autoreleasing error = nil;
    bool isWav = [[audioFile.resourcePath pathExtension] isEqualToString:@"wav"];
    [self buildRecorderFor:audioFile withId:mediaId isWav:isWav error:&error];

    if (error != nil) {
      NSLog(@"Unable to prepare a recorder: %@", [error localizedFailureReason]);
    } else {
      audioFile.recorderPrepared = [audioFile.recorder prepareToRecord];
    }
  }

  [self.commandDelegate sendPluginResult:[CDVPluginResult resultWithStatus:CDVCommandStatus_OK]
                              callbackId:command.callbackId];
  [self.soundOperationLock unlock];
}

- (void)getCurrentLevelAudio:(CDVInvokedUrlCommand *)command
{
  [self.soundOperationLock lock];
  NSString *callbackId = command.callbackId;
  NSString *mediaId = [command argumentAtIndex:0];

  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];
  float level = SILENT_LEVEL_IN_DBFS;

  if ((audioFile != nil) && (audioFile.recorder != nil) && [audioFile.recorder isRecording]) {
    [audioFile.recorder updateMeters];
    level = MIN(MAX([audioFile.recorder peakPowerForChannel:0], SILENT_LEVEL_IN_DBFS), 0.0f);
  }

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                              messageAsDouble:level];
  [self.commandDelegate sendPluginResult:result callbackId:callbackId];
  [self.soundOperationLock unlock];
}

/** Describe the capture configuration a just-started recording is actually using */
- (NSDictionary *)buildRecordingMetadata:(CDVAudioFile *)audioFile isWav:(bool)isWav
{
  NSMutableDictionary *requested = [NSMutableDictionary dictionaryWithDictionary:@{
    @"container" : isWav ? @"wav" : @"mp4",
    @"codec" : isWav ? @"pcm-s16le" : @"aac-lc",
    @"sample_rate_hz" : @(ASSESSMENT_SAMPLE_RATE_IN_HZ),
    @"channel_count" : @(ASSESSMENT_CHANNEL_COUNT),
  }];
  if (!isWav) {
    requested[@"bit_rate_bps"] = @(ASSESSMENT_BIT_RATE_IN_BPS);
  }

  return @{
    @"schema_version" : @(CAPTURE_METADATA_SCHEMA_VERSION),
    @"capture_profile" : isWav ? @"legacy-fallback" : @"assessment-v2",
    @"metadata_source" : @"measured",
    @"platform" : @"ios",
    @"mime_type" : isWav ? @"audio/wav" : @"audio/mp4",
    @"requested" : requested,
  };
}

- (void)getRecordingMetadataAudio:(CDVInvokedUrlCommand *)command
{
  NSString *mediaId = [command argumentAtIndex:0];
  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];

  // Measurement mode is the only way we can say anything definite about the input processing: it
  // disables the platform's echo cancellation, noise suppression and gain control outright.
  BOOL measuring = [self.avSession.mode isEqualToString:AVAudioSessionModeMeasurement];
  NSMutableDictionary *observed = [NSMutableDictionary dictionaryWithDictionary:@{
    @"audio_session_mode" : self.avSession.mode ?: @"unknown",
    @"os_version" : [[NSProcessInfo processInfo] operatingSystemVersionString],
  }];
  if (self.avSession != nil) {
    observed[@"sample_rate_hz"] = @(self.avSession.sampleRate);
    observed[@"channel_count"] = @(self.avSession.inputNumberOfChannels);
  }
  AVAudioSessionPortDescription *input = self.avSession.currentRoute.inputs.firstObject;
  if (input.portType != nil) {
    observed[@"audio_route"] = input.portType;
  }

  // The recording category is set without `allowBluetooth`, so a paired headset never becomes the
  // route even when the system would otherwise default to it. That's on purpose, since Bluetooth
  // input is narrowband and would undo the assessment profile, but the route alone can't tell us
  // it happened: by the time we read it, it already says the built-in microphone.
  NSMutableArray *availableInputs = [NSMutableArray array];
  for (AVAudioSessionPortDescription *port in self.avSession.availableInputs) {
    if (port.portType != nil) {
      [availableInputs addObject:port.portType];
    }
  }
  if (availableInputs.count > 0) {
    observed[@"available_inputs"] = [availableInputs componentsJoinedByString:@","];
  }

  NSMutableDictionary *metadata = [NSMutableDictionary
      dictionaryWithDictionary:audioFile.recordingMetadata ?: [self buildRecordingMetadata:audioFile
                                                                                     isWav:NO]];
  metadata[@"observed"] = observed;
  metadata[@"dsp_flags"] = @{
    @"echo_cancellation" : measuring ? @(NO) : @"unknown",
    @"noise_suppression" : measuring ? @(NO) : @"unknown",
    @"auto_gain_control" : measuring ? @(NO) : @"unknown",
  };

  CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                         messageAsDictionary:metadata];
  [self.commandDelegate sendPluginResult:result callbackId:command.callbackId];
}

- (void)resumeRecordingAudio:(CDVInvokedUrlCommand *)command
{
  NSString *mediaId = [command argumentAtIndex:0];

  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];

  if ((audioFile != nil) && (audioFile.recorder != nil)) {
    NSLog(@"Resumed recording audio sample '%@'", audioFile.resourcePath);
    [audioFile.recorder record];
    // no callback - that will happen in audioRecorderDidFinishRecording
    [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_RUNNING)];
  }
}

- (void)pauseRecordingAudio:(CDVInvokedUrlCommand *)command
{
  NSString *mediaId = [command argumentAtIndex:0];

  CDVAudioFile *audioFile = [[self soundCache] objectForKey:mediaId];

  if ((audioFile != nil) && (audioFile.recorder != nil)) {
    NSLog(@"Paused recording audio sample '%@'", audioFile.resourcePath);
    [audioFile.recorder pause];
    // no callback - that will happen in audioRecorderDidFinishRecording
    [self onStatus:MEDIA_STATE mediaId:mediaId param:@(MEDIA_PAUSED)];
  }
}

- (void)messageChannel:(CDVInvokedUrlCommand *)command
{
  self.statusCallbackId = command.callbackId;
}

- (void)onStatus:(CDVMediaMsg)what mediaId:(NSString *)mediaId param:(NSObject *)param
{
  if (self.statusCallbackId != nil) { // new way, android,windows compatible
    NSMutableDictionary *status = [NSMutableDictionary dictionary];
    status[@"msgType"] = @(what);
    // in the error case contains a dict with "code" and "message"
    // otherwise a NSNumber
    status[@"value"] = param;
    status[@"id"] = mediaId;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"action"] = @"status";
    dict[@"status"] = status;
    CDVPluginResult *result = [CDVPluginResult resultWithStatus:CDVCommandStatus_OK
                                            messageAsDictionary:dict];
    [result setKeepCallbackAsBool:YES]; // we keep this forever
    [self.commandDelegate sendPluginResult:result callbackId:self.statusCallbackId];
  } else { // old school evalJs way
    if (what == MEDIA_ERROR) {
      NSData *jsonData = [NSJSONSerialization dataWithJSONObject:param options:0 error:nil];
      param = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    NSString *jsString =
        [NSString stringWithFormat:@"%@(\"%@\",%d,%@);",
                                   @"cordova.require('cordova-plugin-media.Media').onStatus",
                                   mediaId, (int)what, param];
    [self.commandDelegate evalJs:jsString];
  }
}

- (BOOL)isPlayingOrRecording
{
  for (NSString *mediaId in soundCache) {
    CDVAudioFile *audioFile = [soundCache objectForKey:mediaId];
    if (audioFile.player && [audioFile.player isPlaying]) {
      return true;
    }
    if (audioFile.recorder && [audioFile.recorder isRecording]) {
      return true;
    }
  }
  return false;
}

@end

@implementation CDVAudioFile

@synthesize resourcePath;
@synthesize resourceURL;
@synthesize player, volume, rate;
@synthesize recorder;

@end
@implementation CDVAudioPlayer
@synthesize mediaId;

@end

@implementation CDVAudioRecorder
@synthesize mediaId;

@end
