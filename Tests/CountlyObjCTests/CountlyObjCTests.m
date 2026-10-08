//
//  CountlyObjCTests.m
//
//  This code is provided under the MIT License.
//
//  Please visit www.count.ly for more information.
//

@import XCTest;
@import Countly;

/// Fails every request the SDK sends, so nothing leaves the test and the queue
/// keeps everything it recorded.
@interface CLYFailingURLProtocol : NSURLProtocol
@end

@implementation CLYFailingURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request
{
    return YES;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request
{
    return request;
}

- (void)startLoading
{
    [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorNotConnectedToInternet userInfo:nil]];
}

- (void)stopLoading
{
}

@end

/// Collects every log line the SDK hands its delegate.
@interface CLYCollectingLogger : NSObject <CountlyLoggerDelegate>
@property (nonatomic, readonly) NSMutableArray<NSString *> *lines;
@end

@implementation CLYCollectingLogger

- (instancetype)init
{
    if (self = [super init])
    {
        _lines = NSMutableArray.new;
    }
    return self;
}

- (void)internalLog:(NSString *)log level:(CountlyLogLevel)level
{
    @synchronized (self)
    {
        [self.lines addObject:log];
    }
}

@end

/// The SDK as an Objective-C application uses it. Nothing here goes through a
/// Swift file: every class, selector and constant is the Swift API as the generated
/// header exposes it, so a public API that Objective-C cannot reach fails to build
/// here rather than in an application.
@interface CountlyObjCTests : XCTestCase
@property (nonatomic) CountlyInstance *countly;
@property (nonatomic) CLYCollectingLogger *logger;
@end

@implementation CountlyObjCTests

- (void)setUp
{
    [super setUp];

    NSString *name = [@"objc-" stringByAppendingString:NSUUID.UUID.UUIDString];
    CountlyConfig *config = [[CountlyConfig alloc] initWithAppKey:@"appkey" host:@"https://testing.count.ly"];
    config.instanceName = name;
    config.deviceID = @"objc-device";
    config.manualSessionHandling = YES;
    config.eventSendThreshold = 1;
    config.requiresConsent = YES;
    config.consents = @[@(ConsentFeatureEvents), @(ConsentFeatureViewTracking)];
    config.internalLogLevel = CountlyLogLevelDebug;

    self.logger = CLYCollectingLogger.new;
    config.loggerDelegate = self.logger;

    NSURLSessionConfiguration *session = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    session.protocolClasses = @[CLYFailingURLProtocol.class];
    config.urlSessionConfiguration = session;

    self.countly = [Countly instanceNamed:name];
    [self.countly startWithConfig:config];
}

- (void)tearDown
{
    NSString *name = self.countly.name;
    [self.countly haltWithClearStorage:YES];
    [Countly removeInstanceNamed:name];
    [super tearDown];
}

/// The queued requests that carry `text`.
- (NSArray<NSString *> *)queuedRequestsContaining:(NSString *)text
{
    NSPredicate *carries = [NSPredicate predicateWithBlock:^BOOL(NSString *request, NSDictionary *bindings) {
        return [request containsString:text];
    }];
    return [[self.countly.requestQueue queuedRequests] filteredArrayUsingPredicate:carries];
}

- (void)testTheRegistryHandsBackTheStartedInstance
{
    XCTAssertTrue(self.countly.isStarted);
    XCTAssertEqual([Countly getInstanceNamed:self.countly.name], self.countly);
    XCTAssertTrue([[Countly listInstances] containsObject:self.countly.name]);
    XCTAssertNotNil(Countly.shared);
    XCTAssertNotEqual(Countly.shared, self.countly, "a named instance is not the default one");
}

/// Objective-C can still pass nil for the name. It arrives as an empty name, which
/// is refused rather than read as the default instance.
- (void)testANilNameIsRefusedRatherThanReadAsTheDefaultInstance
{
    NSString *missing = nil;
    CountlyInstance *refused = [Countly instanceNamed:(NSString * _Nonnull)missing];

    XCTAssertEqual(refused.name.length, 0u, "nil arrives as an empty name");
    XCTAssertNotEqual(refused, Countly.shared, "a missing name must not reach the default instance");
    XCTAssertNil([Countly getInstanceNamed:@""]);

    [refused startWithConfig:[[CountlyConfig alloc] initWithAppKey:@"appkey" host:@"https://testing.count.ly"]];

    XCTAssertFalse(refused.isStarted);
}

- (void)testEventsAndViewsReachTheQueue
{
    [self.countly.events recordEvent:@"purchase" segmentation:@{@"sku": @"42"}];
    [self.countly.events recordEvent:@"opened"];
    NSString *viewID = [self.countly.views startView:@"Home" segmentation:nil];
    XCTAssertNotNil(viewID);
    [self.countly.views stopViewWithName:@"Home" segmentation:nil];

    XCTAssertEqual([self queuedRequestsContaining:@"purchase"].count, 1u);
    XCTAssertEqual([self queuedRequestsContaining:@"opened"].count, 1u);
    XCTAssertGreaterThan([self queuedRequestsContaining:@"Home"].count, 0u, "the view never reached the queue");
    XCTAssertGreaterThan(self.logger.lines.count, 0u, "the logger delegate heard nothing");
}

- (void)testConsentTakesArraysOfFeatures
{
    XCTAssertTrue([self.countly.consent hasConsentFor:ConsentFeatureEvents]);
    XCTAssertFalse([self.countly.consent hasConsentFor:ConsentFeatureCrashReporting]);

    [self.countly.consent giveConsentForFeatures:@[@(ConsentFeatureCrashReporting), @(ConsentFeatureUserDetails)]];
    XCTAssertTrue([self.countly.consent hasConsentFor:ConsentFeatureCrashReporting]);
    XCTAssertTrue([self.countly.consent hasConsentFor:ConsentFeatureUserDetails]);

    [self.countly.crashes recordError:@"handled" isFatal:NO stackTrace:nil segmentation:nil];
    XCTAssertEqual([self queuedRequestsContaining:@"crash="].count, 1u);

    [self.countly.consent cancelConsentForFeatures:@[@(ConsentFeatureCrashReporting)]];
    XCTAssertFalse([self.countly.consent hasConsentFor:ConsentFeatureCrashReporting]);
}

- (void)testTheDeviceIDReportsItsTypeAsANumber
{
    XCTAssertEqualObjects(self.countly.deviceID.current, @"objc-device");
    XCTAssertEqualObjects(self.countly.deviceID.type, @(DeviceIDTypeDeveloperSupplied));
    XCTAssertFalse(self.countly.deviceID.isTemporaryIDMode);
}

- (void)testRemoteConfigCallbacksAreRegisteredWithATokenObject
{
    CountlyRCData *missing = [self.countly.remoteConfig getValue:@"not-downloaded"];
    XCTAssertNil(missing.value);
    XCTAssertTrue(missing.isCurrentUsersData);

    RCCallbackToken *token = [self.countly.remoteConfig registerDownloadCallback:^(RequestResult result, NSError *error, BOOL fullValueUpdate, NSDictionary<NSString *, CountlyRCData *> *values) {
    }];
    XCTAssertNotNil(token);
    [self.countly.remoteConfig removeDownloadCallback:token];
}

- (void)testConfigurationValuesSwiftKeepsAsEnumsRoundTrip
{
    CountlyConfig *config = CountlyConfig.new;
    config.features = @[@(CountlyFeatureCrashReporting)];
    config.consents = @[@(ConsentFeatureSessions), @(ConsentFeatureLocation)];
    config.pushTestMode = @(PushTestModeTestFlightOrAdHoc);
    config.content.overlayCornerRadius = @(12);
    config.sdkInternalLimits.maxKeyLength = 64;

    XCTAssertEqualObjects(config.features, @[@(CountlyFeatureCrashReporting)]);
    XCTAssertEqualObjects(config.consents, (@[@(ConsentFeatureSessions), @(ConsentFeatureLocation)]));
    XCTAssertEqualObjects(config.pushTestMode, @(PushTestModeTestFlightOrAdHoc));
    XCTAssertEqualObjects(config.content.overlayCornerRadius, @(12));
    XCTAssertEqual(config.sdkInternalLimits.maxKeyLength, 64);

    config.pushTestMode = nil;
    XCTAssertNil(config.pushTestMode);
    XCTAssertEqualObjects(CountlyMetricKey.appVersion, @"_app_version");
    XCTAssertEqualObjects(CountlyPushKey.countlyPayload, @"c");
}

- (void)testUserPropertiesReachTheQueue
{
    [self.countly.consent giveConsentForFeatures:@[@(ConsentFeatureUserDetails)]];
    [self.countly.userProfile setProperty:@"name" value:@"Ada"];
    [self.countly.userProfile incrementBy:@"visits" value:2];
    [self.countly.userProfile save];

    XCTAssertEqual([self queuedRequestsContaining:@"user_details="].count, 1u);
}

@end
