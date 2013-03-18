//
//  CBLBrowserIDAuthorizer.m
//  CouchbaseLite
//
//  Created by Jens Alfke on 1/9/13.
//
//

#import "CBLBrowserIDAuthorizer.h"
#import "CBLBase64.h"

static NSMutableDictionary* sAssertions;


@implementation CBLBrowserIDAuthorizer


static NSDictionary* decodeComponent(NSArray* components, NSUInteger index) {
    NSData* bodyData = [CBLBase64 decodeURLSafe: components[index]];
    if (!bodyData)
        return nil;
    return $castIf(NSDictionary, [CBLJSON JSONObjectWithData: bodyData options: 0 error: NULL]);
}


static bool parseAssertion(NSString* assertion,
                           NSString** outEmail, NSString** outOrigin, NSDate** outExp)
{
    // https://github.com/mozilla/id-specs/blob/prod/browserid/index.md
    // http://self-issued.info/docs/draft-jones-json-web-token-04.html
    NSArray* components = [assertion componentsSeparatedByString: @"."];
    if (components.count < 4)
        return false;
    NSDictionary* body = decodeComponent(components, 1);
    NSDictionary* principal = $castIf(NSDictionary, body[@"principal"]);
    *outEmail = $castIf(NSString, principal[@"email"]);

    body = decodeComponent(components, 3);
    *outOrigin = $castIf(NSString, body[@"aud"]);
    NSNumber* exp = $castIf(NSNumber, body[@"exp"]);
    *outExp = exp ? [NSDate dateWithTimeIntervalSince1970: exp.doubleValue / 1000.0] : nil;
    return *outEmail != nil && *outOrigin != nil && *outExp != nil;
}


+ (NSURL*) originForSite: (NSURL*)url {
    NSString* scheme = url.scheme.lowercaseString;
    NSMutableString* str = [NSMutableString stringWithFormat: @"%@://%@",
                            scheme, url.host.lowercaseString];
    NSNumber* port = url.port;
    if (port) {
        int defaultPort = [scheme isEqualToString: @"https"] ? 443 : 80;
        if (port.intValue != defaultPort)
            [str appendFormat: @":%@", port];
    }
    [str appendString: @"/"];
    return [NSURL URLWithString: str];
}


+ (NSString*) registerAssertion: (NSString*)assertion {
    NSString* email, *origin;
    NSDate* exp;
    if (!parseAssertion(assertion, &email, &origin, &exp))
        return nil;
    id key = @[email, origin];
    @synchronized(self) {
        if (!sAssertions)
            sAssertions = [NSMutableDictionary dictionary];
        sAssertions[key] = assertion;
    }
    return email;
}


+ (NSString*) takeAssertionForEmailAddress: (NSString*)email
                                      site: (NSURL*)site
{
    id key = @[email, [[self originForSite: site] absoluteString]];
    @synchronized(self) {
        return sAssertions[key];
    }
}


@synthesize emailAddress=_emailAddress;


- (instancetype) initWithEmailAddress: (NSString*)emailAddress {
    self = [super init];
    if (self) {
        if (!emailAddress)
            return nil;
        _emailAddress = [emailAddress copy];
    }
    return self;
}


- (NSString*) assertionForSite: (NSURL*)site {
    NSString* assertion = [[self class] takeAssertionForEmailAddress: _emailAddress site: site];
    if (!assertion)
        return nil;
    NSString* email, *origin;
    NSDate* exp;
    if (!parseAssertion(assertion, &email, &origin, &exp) || exp.timeIntervalSinceNow < 0)
        return nil;
    return assertion;
}


- (NSString*) authorizeURLRequest: (NSMutableURLRequest*)request
                         forRealm: (NSString*)realm
{
    // Auth is via cookie, which is automatically added by CFNetwork.
    return nil;
}


- (NSString*) authorizeHTTPMessage: (CFHTTPMessageRef)message
                          forRealm: (NSString*)realm
{
    // Auth is via cookie, which is automatically added by CFNetwork.
    return nil;
}


- (NSString*) loginPathForSite:(NSURL *)site {
    return [site.path stringByAppendingPathComponent: @"_browserid"];
}


- (NSDictionary*) loginParametersForSite: (NSURL*)site {
    NSString* assertion = [self assertionForSite: site];
    return assertion ? @{@"assertion": assertion} : nil;
}

@end




TestCase(TEBrowserIDAuthorizer) {
    NSString* email, *origin;
    NSDate* exp;
    CAssert(!parseAssertion(@"", &email, &origin, &exp));

    // This is an assertion generated by persona.org on 1/13/2013.
    NSString* sampleAssertion = @"eyJhbGciOiJSUzI1NiJ9.eyJwdWJsaWMta2V5Ijp7ImFsZ29yaXRobSI6IkRTIiwieSI6ImNhNWJiYTYzZmI4MDQ2OGE0MjFjZjgxYTIzN2VlMDcwYTJlOTM4NTY0ODhiYTYzNTM0ZTU4NzJjZjllMGUwMDk0ZWQ2NDBlOGNhYmEwMjNkYjc5ODU3YjkxMzBlZGNmZGZiNmJiNTUwMWNjNTk3MTI1Y2NiMWQ1ZWQzOTVjZTMyNThlYjEwN2FjZTM1ODRiOWIwN2I4MWU5MDQ4NzhhYzBhMjFlOWZkYmRjYzNhNzNjOTg3MDAwYjk4YWUwMmZmMDQ4ODFiZDNiOTBmNzllYzVlNDU1YzliZjM3NzFkYjEzMTcxYjNkMTA2ZjM1ZDQyZmZmZjQ2ZWZiZDcwNjgyNWQiLCJwIjoiZmY2MDA0ODNkYjZhYmZjNWI0NWVhYjc4NTk0YjM1MzNkNTUwZDlmMWJmMmE5OTJhN2E4ZGFhNmRjMzRmODA0NWFkNGU2ZTBjNDI5ZDMzNGVlZWFhZWZkN2UyM2Q0ODEwYmUwMGU0Y2MxNDkyY2JhMzI1YmE4MWZmMmQ1YTViMzA1YThkMTdlYjNiZjRhMDZhMzQ5ZDM5MmUwMGQzMjk3NDRhNTE3OTM4MDM0NGU4MmExOGM0NzkzMzQzOGY4OTFlMjJhZWVmODEyZDY5YzhmNzVlMzI2Y2I3MGVhMDAwYzNmNzc2ZGZkYmQ2MDQ2MzhjMmVmNzE3ZmMyNmQwMmUxNyIsInEiOiJlMjFlMDRmOTExZDFlZDc5OTEwMDhlY2FhYjNiZjc3NTk4NDMwOWMzIiwiZyI6ImM1MmE0YTBmZjNiN2U2MWZkZjE4NjdjZTg0MTM4MzY5YTYxNTRmNGFmYTkyOTY2ZTNjODI3ZTI1Y2ZhNmNmNTA4YjkwZTVkZTQxOWUxMzM3ZTA3YTJlOWUyYTNjZDVkZWE3MDRkMTc1ZjhlYmY2YWYzOTdkNjllMTEwYjk2YWZiMTdjN2EwMzI1OTMyOWU0ODI5YjBkMDNiYmM3ODk2YjE1YjRhZGU1M2UxMzA4NThjYzM0ZDk2MjY5YWE4OTA0MWY0MDkxMzZjNzI0MmEzODg5NWM5ZDViY2NhZDRmMzg5YWYxZDdhNGJkMTM5OGJkMDcyZGZmYTg5NjIzMzM5N2EifSwicHJpbmNpcGFsIjp7ImVtYWlsIjoiamVuc0Btb29zZXlhcmQuY29tIn0sImlhdCI6MTM1ODI5NjIzNzU3NywiZXhwIjoxMzU4MzgyNjM3NTc3LCJpc3MiOiJsb2dpbi5wZXJzb25hLm9yZyJ9.RnDK118nqL2wzpLCVRzw1MI4IThgeWpul9jPl6ypyyxRMMTurlJbjFfs-BXoPaOem878G8-4D2eGWS6wd307k7xlPysevYPogfFWxK_eDHwkTq3Ts91qEDqrdV_JtgULC8c1LvX65E0TwW_GL_TM94g3CvqoQnGVxxoaMVye4ggvR7eOZjimWMzUuu4Lo9Z-VBHBj7XM0UMBie57CpGwH4_Wkv0V_LHZRRHKdnl9ISp_aGwfBObTcHG9v0P3BW9vRrCjihIn0SqOJQ9obl52rMf84GD4Lcy9NIktzfyka70xR9Sh7ALotW7rWywsTzMTu3t8AzMz2MJgGjvQmx49QA~eyJhbGciOiJEUzEyOCJ9.eyJleHAiOjEzNTgyOTY0Mzg0OTUsImF1ZCI6Imh0dHA6Ly9sb2NhbGhvc3Q6NDk4NC8ifQ.4FV2TrUQffDya0MOxOQlzJQbDNvCPF2sfTIJN7KOLvvlSFPknuIo5g";
    CAssert(parseAssertion(sampleAssertion, &email, &origin, &exp));
    CAssertEqual(email, @"jens@mooseyard.com");
    CAssertEqual(origin, @"http://localhost:4984/");
    CAssertEq((SInt64)exp.timeIntervalSinceReferenceDate, 379989238);

    // Register and retrieve the sample assertion:
    NSURL* originURL = [NSURL URLWithString: origin];
    CAssertEqual([CBLBrowserIDAuthorizer registerAssertion: sampleAssertion], email);
    NSString* gotAssertion = [CBLBrowserIDAuthorizer takeAssertionForEmailAddress: email
                                                                            site: originURL];
    CAssertEqual(gotAssertion, sampleAssertion);
    
    // -assertionForSite: should return nil because the assertion has expired by now:
    CBLBrowserIDAuthorizer* auth = [[CBLBrowserIDAuthorizer alloc] initWithEmailAddress: email];
    CAssertEqual(auth.emailAddress, email);
    CAssertEqual([auth assertionForSite: originURL], nil);
}
