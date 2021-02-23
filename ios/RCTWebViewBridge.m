/**
 * Copyright (c) 2015-present, Facebook, Inc.
 * All rights reserved.
 *
 * Copyright (c) 2015-present, Ali Najafizadeh (github.com/alinz)
 * All rights reserved
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "RCTWebViewBridge.h"

#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

#import <React/RCTAutoInsetsProtocol.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTLog.h>
#import <React/RCTUtils.h>
#import <React/RCTView.h>
//#import "UIView+React.h"
#import <objc/runtime.h>

//This is a very elegent way of defining multiline string in objective-c.
//source: http://stackoverflow.com/a/23387659/828487
#define NSStringMultiline(...) [[NSString alloc] initWithCString:#__VA_ARGS__ encoding:NSUTF8StringEncoding]

//we don'e need this one since it has been defined in RCTWebView.m
NSString *const RCTJSNavigationScheme = @"react-js-navigation";
NSString *const RCTWebViewBridgeSchema = @"wvb";
static NSURLCredential* clientAuthenticationCredential;
static NSDictionary* customCertificatesForHost;

// runtime trick to remove WKWebView keyboard default toolbar
// see: http://stackoverflow.com/questions/19033292/ios-7-wkwebview-keyboard-issue/19042279#19042279
@interface _SwizzleHelper : NSObject @end
@implementation _SwizzleHelper
-(id)inputAccessoryView
{
  return nil;
}
@end

@interface RCTWebViewBridge () <WKNavigationDelegate, RCTAutoInsetsProtocol>

@property (nonatomic, copy) RCTDirectEventBlock onLoadingStart;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingFinish;
@property (nonatomic, copy) RCTDirectEventBlock onLoadingError;
@property (nonatomic, copy) RCTDirectEventBlock onShouldStartLoadWithRequest;
@property (nonatomic, copy) RCTDirectEventBlock onBridgeMessage;
@property (nonatomic, copy) RCTDirectEventBlock onHttpError;
@property (nonatomic, copy) RCTDirectEventBlock onFileDownload;
@end

@implementation RCTWebViewBridge
{
  WKWebView *_webView;
  NSString *_injectedJavaScript;
}

- (instancetype)initWithFrame:(CGRect)frame
{
  if ((self = [super initWithFrame:frame])) {
      
    super.backgroundColor = [UIColor clearColor];
    _automaticallyAdjustContentInsets = YES;
    _contentInset = UIEdgeInsetsZero;
      
    _webView = [[WKWebView alloc] initWithFrame:self.bounds];
    _webView.navigationDelegate = self;
      if (@available(iOS 10.0, *)) {
          _webView.configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
      } else {
          // Fallback on earlier versions
          _webView.configuration.requiresUserActionForMediaPlayback = NO;
      }
    [self addSubview:_webView];
  }
  return self;
}

- (void)                    webView:(WKWebView *)webView
  didReceiveAuthenticationChallenge:(NSURLAuthenticationChallenge *)challenge
                  completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition disposition, NSURLCredential * _Nullable))completionHandler
{
    NSString* host = nil;
    if (webView.URL != nil) {
        host = webView.URL.host;
    }
    if ([[challenge protectionSpace] authenticationMethod] == NSURLAuthenticationMethodClientCertificate) {
        completionHandler(NSURLSessionAuthChallengeUseCredential, clientAuthenticationCredential);
        return;
    }
    if ([[challenge protectionSpace] serverTrust] != nil && customCertificatesForHost != nil && host != nil) {
        SecCertificateRef localCertificate = (__bridge SecCertificateRef)([customCertificatesForHost objectForKey:host]);
        if (localCertificate != nil) {
            NSData *localCertificateData = (NSData*) CFBridgingRelease(SecCertificateCopyData(localCertificate));
            SecTrustRef trust = [[challenge protectionSpace] serverTrust];
            long count = SecTrustGetCertificateCount(trust);
            for (long i = 0; i < count; i++) {
                SecCertificateRef serverCertificate = SecTrustGetCertificateAtIndex(trust, i);
                if (serverCertificate == nil) { continue; }
                NSData *serverCertificateData = (NSData *) CFBridgingRelease(SecCertificateCopyData(serverCertificate));
                if ([serverCertificateData isEqualToData:localCertificateData]) {
                    NSURLCredential *useCredential = [NSURLCredential credentialForTrust:trust];
                    if (challenge.sender != nil) {
                        [challenge.sender useCredential:useCredential forAuthenticationChallenge:challenge];
                    }
                    completionHandler(NSURLSessionAuthChallengeUseCredential, useCredential);
                    return;
                }
            }
        }
    }
    completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
}

RCT_NOT_IMPLEMENTED(- (instancetype)initWithCoder:(NSCoder *)aDecoder)

- (void)goForward
{
  [_webView goForward];
}

- (void)goBack
{
  [_webView goBack];
}

- (void)reload
{
  [_webView reload];
}

- (void)sendToBridge:(NSString *)message
{
  //we are warpping the send message in a function to make sure that if
  //WebView is not injected, we don't crash the app.
  NSString *format = NSStringMultiline(
    (function(){
      if (WebViewBridge && WebViewBridge.__push__) {
        WebViewBridge.__push__('%@');
      }
    }());
  );

  // Escape singlequotes or messages containing ' will fail
  NSString *quotedMessage = [message stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
  NSString *command = [NSString stringWithFormat: format, quotedMessage];
    [_webView evaluateJavaScript:command completionHandler:nil];
//  [_webView stringByEvaluatingJavaScriptFromString:command];
//    NSLog(@"*************: %@", command);
}

- (NSURL *)URL
{
  return _webView.URL;
}

- (void)setSource:(NSDictionary *)source
{
  if (![_source isEqualToDictionary:source]) {
    _source = [source copy];

    // Check for a static html source first
    NSString *html = [RCTConvert NSString:source[@"html"]];
    if (html) {
      NSURL *baseURL = [RCTConvert NSURL:source[@"baseUrl"]];
      [_webView loadHTMLString:html baseURL:baseURL];
      return;
    }

    NSURLRequest *request = [RCTConvert NSURLRequest:source];
    // Because of the way React works, as pages redirect, we actually end up
    // passing the redirect urls back here, so we ignore them if trying to load
    // the same url. We'll expose a call to 'reload' to allow a user to load
    // the existing page.
      NSLog(@"+++++++: %@", request.URL);
    if ([request.URL isEqual:_webView.URL]) {
      return;
    }
    if (!request.URL) {
      // Clear the webview
      [_webView loadHTMLString:@"" baseURL:nil];
      return;
    }
    [_webView loadRequest:request];
  }
}

- (void)layoutSubviews
{
  [super layoutSubviews];
  _webView.frame = self.bounds;
}

- (void)setContentInset:(UIEdgeInsets)contentInset
{
  _contentInset = contentInset;
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:NO];
}

- (void)setBackgroundColor:(UIColor *)backgroundColor
{
  CGFloat alpha = CGColorGetAlpha(backgroundColor.CGColor);
  self.opaque = _webView.opaque = (alpha == 1.0);
  _webView.backgroundColor = backgroundColor;
}

- (UIColor *)backgroundColor
{
  return _webView.backgroundColor;
}

- (NSMutableDictionary<NSString *, id> *)baseEvent
{
    __block NSString *resultString = nil;
    __block BOOL finished = NO;

    [_webView evaluateJavaScript:@"document.title" completionHandler:^(id result, NSError *error) {
        if (error == nil) {
            if (result != nil) {
                resultString = [NSString stringWithFormat:@"%@", result];
            }
        } else {
            NSLog(@"evaluateJavaScript error : %@", error.localizedDescription);
        }
        finished = YES;
    }];

    while (!finished)
    {
        [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
    }
    
    NSMutableDictionary<NSString *, id> *event = [[NSMutableDictionary alloc] initWithDictionary:@{
        @"url": _webView.URL.absoluteString ?: @"",
        @"loading" : @(_webView.loading),
        @"title": resultString,
        @"canGoBack": @(_webView.canGoBack),
        @"canGoForward" : @(_webView.canGoForward),
    }];

    return event;
}

- (void)refreshContentInset
{
  [RCTView autoAdjustInsetsForView:self
                    withScrollView:_webView.scrollView
                      updateOffset:YES];
}

-(void)setHideKeyboardAccessoryView:(BOOL)hideKeyboardAccessoryView
{
  if (!hideKeyboardAccessoryView) {
    return;
  }

  UIView* subview;
  for (UIView* view in _webView.scrollView.subviews) {
    if([[view.class description] hasPrefix:@"UIWeb"])
      subview = view;
  }

  if(subview == nil) return;

  NSString* name = [NSString stringWithFormat:@"%@_SwizzleHelper", subview.class.superclass];
  Class newClass = NSClassFromString(name);

  if(newClass == nil)
  {
    newClass = objc_allocateClassPair(subview.class, [name cStringUsingEncoding:NSASCIIStringEncoding], 0);
    if(!newClass) return;

    Method method = class_getInstanceMethod([_SwizzleHelper class], @selector(inputAccessoryView));
      class_addMethod(newClass, @selector(inputAccessoryView), method_getImplementation(method), method_getTypeEncoding(method));

    objc_registerClassPair(newClass);
  }

  object_setClass(subview, newClass);
}

#pragma mark - WKWebViewDelegate methods

- (void)webView:(WKWebView *)webView decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
  BOOL isJSNavigation = [navigationAction.request.URL.scheme isEqualToString:RCTJSNavigationScheme];

  if (!isJSNavigation && [navigationAction.request.URL.scheme isEqualToString:RCTWebViewBridgeSchema]) {
      __block NSString *message = nil;
      __block BOOL finished = NO;
      [webView evaluateJavaScript:@"WebViewBridge.__fetch__()" completionHandler:^(id result, NSError *error) {
          if (error != nil || result == nil) {
              if (error != nil) {
                  NSLog(@"evaluateJavaScript error : %@", error.localizedDescription);
              }
          } else {
              message = [NSString stringWithFormat:@"%@", result];
              finished = YES;
          }
      }];
      
      while (!finished)
      {
          [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
      }
      
      NSMutableDictionary<NSString *, id> *onBridgeMessageEvent = [[NSMutableDictionary alloc] initWithDictionary:@{
        @"messages": [self stringArrayJsonToArray: message]
      }];

      _onBridgeMessage(onBridgeMessageEvent);

      isJSNavigation = YES;
  }

  // skip this for the JS Navigation handler
  if (!isJSNavigation && _onShouldStartLoadWithRequest) {
    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary: @{
      @"url": (navigationAction.request.URL).absoluteString,
      @"navigationType": @(navigationAction.navigationType)
    }];
    if (![self.delegate webView:self
      shouldStartLoadForRequest:event
                   withCallback:_onShouldStartLoadWithRequest]) {
      decisionHandler(WKNavigationActionPolicyCancel);
        return;
    }
  }

  if (_onLoadingStart) {
    // We have this check to filter out iframe requests and whatnot
    BOOL isTopFrame = [navigationAction.request.URL isEqual:navigationAction.request.mainDocumentURL];
    if (isTopFrame) {
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      [event addEntriesFromDictionary: @{
        @"url": (navigationAction.request.URL).absoluteString,
        @"navigationType": @(navigationAction.navigationType)
      }];
      _onLoadingStart(event);
    }
  }
  // JS Navigation handler
  decisionHandler(WKNavigationActionPolicyAllow);
}

/**
 * Decides whether to allow or cancel a navigation after its response is known.
 * @see https://developer.apple.com/documentation/webkit/wknavigationdelegate/1455643-webview?language=objc
 */
- (void)                    webView:(WKWebView *)webView
  decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
                    decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
  WKNavigationResponsePolicy policy = WKNavigationResponsePolicyAllow;
  if (_onHttpError && navigationResponse.forMainFrame) {
    if ([navigationResponse.response isKindOfClass:[NSHTTPURLResponse class]]) {
      NSHTTPURLResponse *response = (NSHTTPURLResponse *)navigationResponse.response;
      NSInteger statusCode = response.statusCode;

      if (statusCode >= 400) {
        NSMutableDictionary<NSString *, id> *httpErrorEvent = [self baseEvent];
        [httpErrorEvent addEntriesFromDictionary: @{
          @"url": response.URL.absoluteString,
          @"statusCode": @(statusCode)
        }];

        _onHttpError(httpErrorEvent);
      }

      NSString *disposition = nil;
      if (@available(iOS 13, *)) {
        disposition = [response valueForHTTPHeaderField:@"Content-Disposition"];
      }
      BOOL isAttachment = disposition != nil && [disposition hasPrefix:@"attachment"];
      if (isAttachment || !navigationResponse.canShowMIMEType) {
        if (_onFileDownload) {
          policy = WKNavigationResponsePolicyCancel;

          NSMutableDictionary<NSString *, id> *downloadEvent = [self baseEvent];
          [downloadEvent addEntriesFromDictionary: @{
            @"downloadUrl": (response.URL).absoluteString,
          }];
          _onFileDownload(downloadEvent);
        }
      }
    }
  }

  decisionHandler(policy);
}

/**
 * Called when an error occurs while the web view is loading content.
 * @see https://fburl.com/km6vqenw
 */
- (void)               webView:(WKWebView *)webView
  didFailProvisionalNavigation:(WKNavigation *)navigation
                     withError:(NSError *)error
{
  if (_onLoadingError) {
    if ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled) {
      // NSURLErrorCancelled is reported when a page has a redirect OR if you load
      // a new URL in the WebView before the previous one came back. We can just
      // ignore these since they aren't real errors.
      // http://stackoverflow.com/questions/1024748/how-do-i-fix-nsurlerrordomain-error-999-in-iphone-3-0-os
      return;
    }

    if ([error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 102 || [error.domain isEqualToString:@"WebKitErrorDomain"] && error.code == 101) {
      // Error code 102 "Frame load interrupted" is raised by the WKWebView
      // when the URL is from an http redirect. This is a common pattern when
      // implementing OAuth with a WebView.
      return;
    }

    NSMutableDictionary<NSString *, id> *event = [self baseEvent];
    [event addEntriesFromDictionary:@{
      @"didFailProvisionalNavigation": @YES,
      @"domain": error.domain,
      @"code": @(error.code),
      @"description": error.localizedDescription,
    }];
    _onLoadingError(event);
  }
}

- (void)evaluateJS:(NSString *)js
          thenCall: (void (^)(NSString*)) callback
{
  [_webView evaluateJavaScript: js completionHandler: ^(id result, NSError *error) {
    if (callback != nil) {
      callback([NSString stringWithFormat:@"%@", result]);
    }
    if (error != nil) {
      RCTLogWarn(@"%@", [NSString stringWithFormat:@"Error evaluating injectedJavaScript: This is possibly due to an unsupported return type. Try adding true to the end of your injectedJavaScript string. %@", error]);
    }
  }];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(null_unspecified WKNavigation *)navigation
{
  //injecting WebViewBridge Script
  NSString *webViewBridgeScriptContent = [self webViewBridgeScript];
  [webView evaluateJavaScript:webViewBridgeScriptContent completionHandler:nil];
  //////////////////////////////////////////////////////////////////////////////
    __block NSString *jsEvaluationValue = nil;
    __block BOOL finished = NO;

  if (_injectedJavaScript != nil) {
      [_webView evaluateJavaScript:_injectedJavaScript completionHandler:^(id result, NSError *error) {
          if (error == nil) {
              if (result != nil) {
                  jsEvaluationValue = [NSString stringWithFormat:@"%@", result];
              }
          } else {
              NSLog(@"evaluateJavaScript error : %@", error.localizedDescription);
          }
          finished = YES;
      }];

      while (!finished)
      {
          [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]];
      }
      
      NSMutableDictionary<NSString *, id> *event = [self baseEvent];
      event[@"jsEvaluationValue"] = jsEvaluationValue;
      NSLog(@"+++++++++++: %@", jsEvaluationValue);
      _onLoadingFinish(event);
  }
  // we only need the final 'finishLoad' call so only fire the event when we're actually done loading.
  else if (_onLoadingFinish && !webView.loading && ![webView.URL.absoluteString isEqualToString:@"about:blank"]) {
    _onLoadingFinish([self baseEvent]);
  }
}

- (NSArray*)stringArrayJsonToArray:(NSString *)message
{
  return [NSJSONSerialization JSONObjectWithData:[message dataUsingEncoding:NSUTF8StringEncoding]
                                         options:NSJSONReadingAllowFragments
                                           error:nil];
}

//since there is no easy way to load the static lib resource in ios,
//we are loading the script from this method.
- (NSString *)webViewBridgeScript {
  // NSBundle *bundle = [NSBundle mainBundle];
  // NSString *webViewBridgeScriptFile = [bundle pathForResource:@"webviewbridge"
  //                                                      ofType:@"js"];
  // NSString *webViewBridgeScriptContent = [NSString stringWithContentsOfFile:webViewBridgeScriptFile
  //                                                                  encoding:NSUTF8StringEncoding
  //                                                                     error:nil];

  return NSStringMultiline(
    (function (window) {
      'use strict';

      //Make sure that if WebViewBridge already in scope we don't override it.
      if (window.WebViewBridge) {
        return;
      }

      var RNWBSchema = 'wvb';
      var sendQueue = [];
      var receiveQueue = [];
      var doc = window.document;
      var customEvent = doc.createEvent('Event');

      function callFunc(func, message) {
        if ('function' === typeof func) {
          func(message);
        }
      }

      function signalNative() {
        window.location = RNWBSchema + '://message' + new Date().getTime();
      }

      //I made the private function ugly signiture so user doesn't called them accidently.
      //if you do, then I have nothing to say. :(
      var WebViewBridge = {
        //this function will be called by native side to push a new message
        //to webview.
        __push__: function (message) {
          receiveQueue.push(message);
          //reason I need this setTmeout is to return this function as fast as
          //possible to release the native side thread.
          setTimeout(function () {
            var message = receiveQueue.pop();
            callFunc(WebViewBridge.onMessage, message);
          }, 15); //this magic number is just a random small value. I don't like 0.
        },
        __fetch__: function () {
          //since our sendQueue array only contains string, and our connection to native
          //can only accept string, we need to convert array of strings into single string.
          var messages = JSON.stringify(sendQueue);

          //we make sure that sendQueue is resets
          sendQueue = [];

          //return the messages back to native side.
          return messages;
        },
        //make sure message is string. because only string can be sent to native,
        //if you don't pass it as string, onError function will be called.
        send: function (message) {
          if ('string' !== typeof message) {
            callFunc(WebViewBridge.onError, "message is type '" + typeof message + "', and it needs to be string");
            return;
          }

          //we queue the messages to make sure that native can collects all of them in one shot.
          sendQueue.push(message);
          //signal the objective-c that there is a message in the queue
          signalNative();
        },
        onMessage: null,
        onError: null
      };

      window.WebViewBridge = WebViewBridge;

      //dispatch event
      customEvent.initEvent('WebViewBridge', true, true);
      doc.dispatchEvent(customEvent);
    }(window));
  );
}

@end
