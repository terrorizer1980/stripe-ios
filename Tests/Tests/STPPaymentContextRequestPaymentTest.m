//
//  STPPaymentContextPaymentMethodsTest.m
//  Stripe
//
//  Created by Ben Guo on 4/5/17.
//  Copyright © 2017 Stripe, Inc. All rights reserved.
//

#import <XCTest/XCTest.h>
#import <OCMock/OCMock.h>
#import <SafariServices/SafariServices.h>
#import "UIViewController+Stripe_Promises.h"
#import "STPAPIClient.h"
#import "STPFixtures.h"
#import "STPFormEncoder.h"
#import "STPMocks.h"
#import "STPPaymentContext+Private.h"

@interface STPPaymentContext (Testing)
@property(nonatomic)id<STPPaymentMethod> selectedPaymentMethod;
@property(nonatomic, assign) STPPaymentContextState state;
@property(nonatomic)STPAPIClient *apiClient;
@end

@interface STPSourceInfoViewController (Testing)
@property(nonatomic, copy)STPSourceInfoCompletionBlock completion;
@end

@interface STPPaymentContextRequestPaymentTest : XCTestCase

@end

/**
 These tests cover STPPaymentContext's requestPayment method
 */
@implementation STPPaymentContextRequestPaymentTest

- (STPPaymentContext *)buildPaymentContextWithCustomer:(STPCustomer *)customer
                                         configuration:(STPPaymentConfiguration *)config {
    STPTheme *theme = [STPTheme defaultTheme];
    id<STPBackendAPIAdapter> mockAPIAdapter = [STPMocks staticAPIAdapterWithCustomer:customer];
    STPPaymentContext *paymentContext = [[STPPaymentContext alloc] initWithAPIAdapter:mockAPIAdapter
                                                                        configuration:config
                                                                                theme:theme];
    return paymentContext;
}

/**
 When selectedPaymentMethod is nil, STPPaymentMethodsVC should be presented.
 */
- (void)testRequestPaymentWithNoSelectedPaymentMethod {
    STPCustomer *customer = [STPFixtures customerWithNoSources];
    STPPaymentConfiguration *config = [STPFixtures paymentConfiguration];
    STPPaymentContext *sut = [self buildPaymentContextWithCustomer:customer
                                                     configuration:config];
    XCTAssertNil(sut.selectedPaymentMethod);
    XCTAssertEqual(sut.state, STPPaymentContextStateNone);
    id mockVC = [STPMocks hostViewController];
    sut.hostViewController = mockVC;

    [sut requestPayment];

    BOOL (^checker)() = ^BOOL(id vc) {
        XCTAssertEqual(sut.state, STPPaymentContextStateRequestingPayment);
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nc = (UINavigationController *)vc;
            return [nc.topViewController isKindOfClass:[STPPaymentMethodsViewController class]];
        }
        return NO;
    };
    OCMVerify([mockVC presentViewController:[OCMArg checkWithBlock:checker]
                                   animated:YES
                                 completion:[OCMArg any]]);
}

/**
 When a shipping address is required, STPShippingAddressVC should be presented
 */
- (void)testRequestPaymentWithNoShippingAddress {
    STPCustomer *customer = [STPFixtures customerWithSingleCardTokenSource];
    STPPaymentConfiguration *config = [STPFixtures paymentConfiguration];
    config.requiredShippingAddressFields = PKAddressFieldAll;
    STPPaymentContext *sut = [self buildPaymentContextWithCustomer:customer
                                                     configuration:config];
    XCTAssertNotNil(sut.selectedPaymentMethod);
    XCTAssertNil(sut.shippingAddress);
    XCTAssertEqual(sut.state, STPPaymentContextStateNone);
    id mockVC = [STPMocks hostViewController];
    sut.hostViewController = mockVC;

    [sut requestPayment];

    BOOL (^checker)() = ^BOOL(id vc) {
        XCTAssertEqual(sut.state, STPPaymentContextStateRequestingPayment);
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nc = (UINavigationController *)vc;
            return [nc.topViewController isKindOfClass:[STPShippingAddressViewController class]];
        }
        return NO;
    };
    OCMVerify([mockVC presentViewController:[OCMArg checkWithBlock:checker]
                                   animated:YES
                                 completion:[OCMArg any]]);
}


/**
 When selectedPaymentMethod is iDEAL, STPSourceInfoVC should be presented.
 When STPSourceInfoVC's completion block is called with iDEAL source params,
 createSource should be called with those params, after which SFSafariVC
 should be presented.
 */
- (void)testRequestPaymentWithIDEALSourceSelected {
    STPCustomer *customer = [STPFixtures customerWithNoSources];
    STPPaymentConfiguration *config = [STPFixtures paymentConfiguration];
    config.returnURL = [NSURL URLWithString:@"test://redirect"];
    STPPaymentContext *sut = [self buildPaymentContextWithCustomer:customer
                                                     configuration:config];
    id mockVC = [STPMocks hostViewController];
    sut.hostViewController = mockVC;
    id mockAPIClient = OCMClassMock([STPAPIClient class]);
    sut.apiClient = mockAPIClient;
    sut.selectedPaymentMethod = [STPPaymentMethodType ideal];
    XCTAssertEqual(sut.state, STPPaymentContextStateNone);

    STPSourceParams *expectedParams = [STPSourceParams idealParamsWithAmount:1099 name:@"Jenny Rosen" returnURL:@"test://redirect" statementDescriptor:nil bank:nil];

    XCTestExpectation *sourceInfoExp = [self expectationWithDescription:@"presented SourceInfoVC"];
    XCTestExpectation *safariExp = [self expectationWithDescription:@"present SafariVC"];
    BOOL (^checker)() = ^BOOL(id vc) {
        XCTAssertEqual(sut.state, STPPaymentContextStateRequestingPayment);
        if ([vc isKindOfClass:[UINavigationController class]]) {
            UINavigationController *nc = (UINavigationController *)vc;
            if ([nc.topViewController isKindOfClass:[STPSourceInfoViewController class]]) {
                STPSourceInfoViewController *sourceInfoVC = (STPSourceInfoViewController *)nc.topViewController;
                sourceInfoVC.completion(expectedParams);
                [sourceInfoExp fulfill];
                return YES;
            };
        }
        if ([vc isKindOfClass:[SFSafariViewController class]]) {
            [safariExp fulfill];
            return YES;
        }
        return NO;
    };
    OCMStub([mockVC presentViewController:[OCMArg checkWithBlock:checker]
                                 animated:YES
                               completion:[OCMArg any]]);

    STPSource *expectedSource = [STPFixtures iDEALSource];
    XCTestExpectation *createSourceExp = [self expectationWithDescription:@"createSource"];
    OCMStub([mockAPIClient createSourceWithParams:[OCMArg any] completion:[OCMArg any]])
    .andDo(^(NSInvocation *invocation){
        STPSourceParams *sourceParams;
        STPSourceCompletionBlock completion;
        [invocation getArgument:&sourceParams atIndex:2];
        [invocation getArgument:&completion atIndex:3];
        NSDictionary *dict = [STPFormEncoder dictionaryForObject:sourceParams];
        NSDictionary *expectedDict = [STPFormEncoder dictionaryForObject:expectedParams];
        XCTAssertEqualObjects(dict, expectedDict);
        completion(expectedSource, nil);
        [createSourceExp fulfill];
    });

    [sut requestPayment];

    [self waitForExpectationsWithTimeout:2 handler:nil];
}

/**
 When selectedPaymentMethod is ApplePay, PKPaymentAuthVC should be presented.
 */
- (void)testRequestPaymentWithApplePaySelected {
    STPCustomer *customer = [STPFixtures customerWithNoSources];
    STPPaymentConfiguration *config = [STPFixtures paymentConfiguration];
    config.appleMerchantIdentifier = @"fake_merchant_id";
    config.companyName = @"Test Company";
    STPPaymentContext *sut = [self buildPaymentContextWithCustomer:customer
                                                     configuration:config];
    sut.paymentAmount = 150;
    id mockVC = [STPMocks hostViewController];
    sut.hostViewController = mockVC;
    sut.selectedPaymentMethod = [STPPaymentMethodType applePay];
    XCTAssertEqual(sut.state, STPPaymentContextStateNone);

    [sut requestPayment];

    BOOL (^checker)() = ^BOOL(id vc) {
        XCTAssertEqual(sut.state, STPPaymentContextStateRequestingPayment);
        return [vc isKindOfClass:[PKPaymentAuthorizationViewController class]];
    };
    OCMVerify([mockVC presentViewController:[OCMArg checkWithBlock:checker]
                                   animated:YES
                                 completion:[OCMArg any]]);
}

/**
 When selectedPaymentMethod is a legacy STPCard, didCreatePaymentResult should be
 called with the correct STPPaymentResult.
 */
- (void)testRequestPaymentWithSTPCardSelected {
    STPCustomer *customer = [STPFixtures customerWithSingleCardTokenSource];
    STPPaymentConfiguration *config = [STPFixtures paymentConfiguration];
    STPPaymentContext *sut = [self buildPaymentContextWithCustomer:customer
                                                     configuration:config];
    XCTAssertTrue([sut.selectedPaymentMethod isKindOfClass:[STPCard class]]);
    id mockVC = [STPMocks hostViewController];
    sut.hostViewController = mockVC;
    id mockDelegate = OCMProtocolMock(@protocol(STPPaymentContextDelegate));
    sut.delegate = mockDelegate;
    XCTAssertEqual(sut.state, STPPaymentContextStateNone);
    XCTestExpectation *exp = [self expectationWithDescription:@"didCreatePaymentResult"];
    OCMStub([mockDelegate paymentContext:[OCMArg any] didCreatePaymentResult:[OCMArg any] completion:[OCMArg any]])
    .andDo(^(NSInvocation *invocation){
        XCTAssertEqual(sut.state, STPPaymentContextStateRequestingPayment);
        STPPaymentResult *result;
        STPErrorBlock completion;
        [invocation getArgument:&result atIndex:3];
        [invocation getArgument:&completion atIndex:4];
        XCTAssertEqual(result.source, customer.defaultSource);
        completion(nil);
        OCMVerify([mockDelegate paymentContext:[OCMArg any] didFinishWithStatus:STPPaymentStatusSuccess
                                         error:[OCMArg isNil]]);
        XCTAssertEqual(sut.state, STPPaymentContextStateNone);
        [exp fulfill];
    });

    [sut requestPayment];
    [self waitForExpectationsWithTimeout:2 handler:nil];
}

/**
 When selectedPaymentMethod is a SEPA Debit source, didCreatePaymentResult
 should be called with the correct STPPaymentResult.
 */
- (void)testRequestPaymentWithSEPADebitSourceSelected {
    STPCustomer *customer = [STPFixtures customerWithSingleSEPADebitSource];
    STPPaymentConfiguration *config = [STPFixtures paymentConfiguration];
    config.availablePaymentMethodTypes = @[[STPPaymentMethodType sepaDebit]];
    STPPaymentContext *sut = [self buildPaymentContextWithCustomer:customer
                                                     configuration:config];
    XCTAssertTrue([sut.selectedPaymentMethod isKindOfClass:[STPSource class]]);
    XCTAssertTrue([sut.selectedPaymentMethod.paymentMethodType isEqual:[STPPaymentMethodType sepaDebit]]);
    id mockVC = [STPMocks hostViewController];
    sut.hostViewController = mockVC;
    id mockDelegate = OCMProtocolMock(@protocol(STPPaymentContextDelegate));
    sut.delegate = mockDelegate;
    XCTAssertEqual(sut.state, STPPaymentContextStateNone);
    XCTestExpectation *exp = [self expectationWithDescription:@"didCreatePaymentResult"];
    OCMStub([mockDelegate paymentContext:[OCMArg any] didCreatePaymentResult:[OCMArg any] completion:[OCMArg any]])
    .andDo(^(NSInvocation *invocation){
        XCTAssertEqual(sut.state, STPPaymentContextStateRequestingPayment);
        STPPaymentResult *result;
        STPErrorBlock completion;
        [invocation getArgument:&result atIndex:3];
        [invocation getArgument:&completion atIndex:4];
        XCTAssertEqual(result.source, customer.defaultSource);
        completion(nil);
        OCMVerify([mockDelegate paymentContext:[OCMArg any] didFinishWithStatus:STPPaymentStatusSuccess
                                         error:[OCMArg isNil]]);
        XCTAssertEqual(sut.state, STPPaymentContextStateNone);
        [exp fulfill];
    });

    [sut requestPayment];
    [self waitForExpectationsWithTimeout:2 handler:nil];
}

/**
 When the completion block of didCreatePaymentResult is called with an error,
 didFinishWithStatus should be called with StatusError and the error.
 */
- (void)testDidCreatePaymentResultWithErrorReturnsErrorToDidFinishWithStatus {
    STPCustomer *customer = [STPFixtures customerWithSingleCardTokenSource];
    STPPaymentConfiguration *config = [STPFixtures paymentConfiguration];
    STPPaymentContext *sut = [self buildPaymentContextWithCustomer:customer
                                                     configuration:config];
    XCTAssertTrue([sut.selectedPaymentMethod isKindOfClass:[STPCard class]]);
    id mockVC = [STPMocks hostViewController];
    sut.hostViewController = mockVC;
    id mockDelegate = OCMProtocolMock(@protocol(STPPaymentContextDelegate));
    sut.delegate = mockDelegate;
    XCTAssertEqual(sut.state, STPPaymentContextStateNone);
    NSError *expectedError = [[NSError alloc] initWithDomain:@"com.stripe.tests" code:0 userInfo:nil];
    XCTestExpectation *exp = [self expectationWithDescription:@"didCreatePaymentResult"];
    OCMStub([mockDelegate paymentContext:[OCMArg any] didCreatePaymentResult:[OCMArg any] completion:[OCMArg any]])
    .andDo(^(NSInvocation *invocation){
        XCTAssertEqual(sut.state, STPPaymentContextStateRequestingPayment);
        STPErrorBlock completion;
        [invocation getArgument:&completion atIndex:4];
        completion(expectedError);
        OCMVerify([mockDelegate paymentContext:[OCMArg any] didFinishWithStatus:STPPaymentStatusError
                                         error:[OCMArg isEqual:expectedError]]);
        XCTAssertEqual(sut.state, STPPaymentContextStateNone);
        [exp fulfill];
    });

    [sut requestPayment];
    [self waitForExpectationsWithTimeout:2 handler:nil];
}

@end
