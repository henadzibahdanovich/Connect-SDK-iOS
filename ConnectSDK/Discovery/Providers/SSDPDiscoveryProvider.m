//
//  SSDPDiscoveryProvider.m
//  Connect SDK
//
//  Created by Andrew Longstaff on 9/6/13.
//  Copyright (c) 2014 LG Electronics. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "SSDPDiscoveryProvider.h"
#import "ServiceDescription.h"
#import "SSDPSocketListener.h"
#import "XMLReader.h"

#import <sys/utsname.h>

#define kSSDP_multicast_address @"239.255.255.250"
#define kSSDP_port 1900

// credit: http://stackoverflow.com/a/1108927/2715
NSString* machineName()
{
    struct utsname systemInfo;
    uname(&systemInfo);

    return [NSString stringWithCString:systemInfo.machine encoding:NSUTF8StringEncoding];
}

@interface SSDPDiscoveryProvider() <SocketListenerDelegate, NSXMLParserDelegate>
{
    NSString *_ssdpHostName;

    SSDPSocketListener *_multicastSocket;
    SSDPSocketListener *_searchSocket;

    NSArray *_serviceFilters;
    NSMutableDictionary *_foundServices;

    NSTimer *_refreshTimer;

    NSMutableDictionary *_helloDevices;
    NSOperationQueue *_locationLoadQueue;
}

@end

@implementation SSDPDiscoveryProvider

static double refreshTime = 10.0;
static double searchAttemptsBeforeKill = 3.0;

#pragma mark - Setup/creation

- (instancetype) init
{
    self = [super init];
    
    if (self)
    {
        _ssdpHostName = [NSString stringWithFormat:@"%@:%d", kSSDP_multicast_address, kSSDP_port];

        _foundServices = [[NSMutableDictionary alloc] init];
        _serviceFilters = [[NSMutableArray alloc] init];
        
        _locationLoadQueue = [[NSOperationQueue alloc] init];
        _locationLoadQueue.maxConcurrentOperationCount = 10;
        
        self.isRunning = NO;
    }
    
    return self;
}

#pragma mark - Control methods

- (void) startDiscovery
{
    if (!self.isRunning)
    {
        self.isRunning = YES;
        [self start];
    }
}

- (void) stopDiscovery
{
    [NSObject cancelPreviousPerformRequestsWithTarget:self];

    if (_searchSocket)
        [_searchSocket close];

    if (_multicastSocket)
        [_multicastSocket close];

    if (_refreshTimer)
        [_refreshTimer invalidate];
    
    self.isRunning = NO;
    
    _searchSocket = nil;
    _multicastSocket = nil;
    _refreshTimer = nil;
}

- (void) start
{
    if (_refreshTimer == nil)
    {
        _refreshTimer = [NSTimer scheduledTimerWithTimeInterval:refreshTime target:self selector:@selector(sendSearchRequests:) userInfo:nil repeats:YES];
        
        [self sendSearchRequests:NO];
    }
}

#pragma mark - Device filter management

- (void)addDeviceFilter:(NSDictionary *)parameters
{
    NSDictionary *ssdpInfo = [parameters objectForKey:@"ssdp"];
    NSAssert(ssdpInfo != nil, @"This device filter does not have ssdp discovery info");
    
    NSString *searchFilter = [ssdpInfo objectForKey:@"filter"];
    NSAssert(searchFilter != nil, @"The ssdp info for this device filter has no search filter parameter");

    _serviceFilters = [_serviceFilters arrayByAddingObject:parameters];
}

- (void)removeDeviceFilter:(NSDictionary *)parameters
{
    NSString *searchTerm = [parameters objectForKey:@"serviceId"];
    __block BOOL shouldRemove = NO;
    __block NSUInteger removalIndex;
    
    [_serviceFilters enumerateObjectsUsingBlock:^(NSDictionary *searchFilter, NSUInteger idx, BOOL *stop) {
        NSString *serviceId = [searchFilter objectForKey:@"serviceId"];
        
        if ([serviceId isEqualToString:searchTerm])
        {
            shouldRemove = YES;
            removalIndex = idx;
            *stop = YES;
        }
    }];
    
    if (shouldRemove)
    {
        NSMutableArray *mutableFilters = [NSMutableArray arrayWithArray:_serviceFilters];
        [mutableFilters removeObjectAtIndex:removalIndex];
        _serviceFilters = [NSArray arrayWithArray:mutableFilters];
    }
}

#pragma mark - SSDP M-SEARCH Request

- (void) sendSearchRequests:(BOOL)shouldKillInactiveDevices
{
    [_serviceFilters enumerateObjectsUsingBlock:^(NSDictionary *info, NSUInteger idx, BOOL *stop) {
        NSDictionary *ssdpInfo = [info objectForKey:@"ssdp"];
        NSString *searchFilter = [ssdpInfo objectForKey:@"filter"];
        NSString *userAgentToken = [ssdpInfo objectForKey:@"userAgentToken"];
        
        [self sendRequestForFilter:searchFilter userAgentToken:userAgentToken killInactiveDevices:shouldKillInactiveDevices];
    }];
}

- (void) sendRequestForFilter:(NSString *)filter userAgentToken:(NSString *)userAgentToken killInactiveDevices:(BOOL)shouldKillInactiveDevices
{
    if (shouldKillInactiveDevices)
    {
        BOOL refresh = NO;
        NSMutableArray *killKeys = [NSMutableArray array];
        
        // 3 detection attempts, if still not present then kill it.
        double killPoint = [[NSDate date] timeIntervalSince1970] - (refreshTime * searchAttemptsBeforeKill);

        @synchronized (_foundServices)
        {
            for (NSString *key in _foundServices)
            {
                ServiceDescription *service = (ServiceDescription *) [_foundServices objectForKey:key];

                if (service.lastDetection < killPoint)
                {
                    [killKeys addObject:key];
                    refresh = YES;
                }
            }

            if (refresh)
            {
                [killKeys enumerateObjectsUsingBlock:^(id key, NSUInteger idx, BOOL *stop)
                {
                    ServiceDescription *service = [_foundServices objectForKey:key];

                    dispatch_async(dispatch_get_main_queue(), ^
                    {
                        [self.delegate discoveryProvider:self didLoseService:service];
                    });

                    [_foundServices removeObjectForKey:key];
                }];
            }
        }
    }
    
    CFHTTPMessageRef theSearchRequest = CFHTTPMessageCreateRequest(NULL, CFSTR("M-SEARCH"),
                                                                   (__bridge  CFURLRef)[NSURL URLWithString: @"*"], kCFHTTPVersion1_1);
    CFHTTPMessageSetHeaderFieldValue(theSearchRequest, CFSTR("HOST"), (__bridge  CFStringRef) _ssdpHostName);
    CFHTTPMessageSetHeaderFieldValue(theSearchRequest, CFSTR("MAN"), CFSTR("\"ssdp:discover\""));
    CFHTTPMessageSetHeaderFieldValue(theSearchRequest, CFSTR("MX"), CFSTR("5"));
    CFHTTPMessageSetHeaderFieldValue(theSearchRequest, CFSTR("ST"),  (__bridge  CFStringRef)filter);
    CFHTTPMessageSetHeaderFieldValue(theSearchRequest, CFSTR("USER-AGENT"), (__bridge CFStringRef)[self userAgentForToken:userAgentToken]);

    NSData *message = CFBridgingRelease(CFHTTPMessageCopySerializedMessage(theSearchRequest));
    
    if (!_searchSocket)
    {
		_searchSocket = [[SSDPSocketListener alloc] initWithAddress:kSSDP_multicast_address andPort:0];
		_searchSocket.delegate = self;
        [_searchSocket open];
    }

    if (!_multicastSocket)
    {
		_multicastSocket = [[SSDPSocketListener alloc] initWithAddress:kSSDP_multicast_address andPort:kSSDP_port];
		_multicastSocket.delegate = self;
        [_multicastSocket open];
    }

    [_searchSocket sendData:message toAddress:kSSDP_multicast_address andPort:kSSDP_port];
    [self performBlock:^{ [_searchSocket sendData:message toAddress:kSSDP_multicast_address andPort:kSSDP_port]; } afterDelay:1];
    [self performBlock:^{ [_searchSocket sendData:message toAddress:kSSDP_multicast_address andPort:kSSDP_port]; } afterDelay:2];
    
    CFRelease(theSearchRequest);
}

#pragma mark - M-SEARCH Response Processing

//* UDPSocket-delegate-method handle anew messages
//* All messages from devices handling here
- (void)socket:(SSDPSocketListener *)aSocket didReceiveData:(NSData *)aData fromAddress:(NSString *)anAddress
{
    // Try to create a HTTPMessage from received data.
    
	CFHTTPMessageRef theHTTPMessage = CFHTTPMessageCreateEmpty(kCFAllocatorDefault, TRUE);
	CFHTTPMessageAppendBytes(theHTTPMessage, aData.bytes, aData.length);

    // We awaiting for receiving a complete header. If it not - just skip it.
	if (CFHTTPMessageIsHeaderComplete(theHTTPMessage))
	{
        
        // Receive some important data from the header
		NSString *theRequestMethod = CFBridgingRelease (CFHTTPMessageCopyRequestMethod(theHTTPMessage));
		NSInteger theCode = CFHTTPMessageGetResponseStatusCode(theHTTPMessage);
		NSDictionary *theHeaderDictionary = CFBridgingRelease(CFHTTPMessageCopyAllHeaderFields(theHTTPMessage));
        
		BOOL isNotify = [theRequestMethod isEqualToString:@"NOTIFY"];
		NSString *theType = (isNotify) ? theHeaderDictionary[@"NT"] : theHeaderDictionary[@"ST"];
        
        // There is 3 possible methods in SSDP:
        // 1) M-SEARCH - for search requests - skip it
        // 2) NOTIFY - for devices notification: advertisements ot bye-bye
        // 3) * with CODE 200 - answer for M-SEARCH request
        
		if (theCode == 200 && ![theRequestMethod isEqualToString:@"M-SEARCH"]
			&& [self isSearchingForFilter:theType])
		{
            // Obtain a unique service id ID - USN.
			NSString *theUSSNKey = theHeaderDictionary[@"USN"];
            if (theUSSNKey == nil || theUSSNKey.length == 0) return;
            
            //Extract the UUID
            NSRegularExpression *reg = [[NSRegularExpression alloc] initWithPattern:@"(?:uuid:).*(?:::)" options:0 error:nil];
            NSString *theUUID;
            NSTextCheckingResult *match = [reg firstMatchInString:theUSSNKey options:0 range:NSMakeRange(0, [theUSSNKey length])];
            
            NSRange range = [match rangeAtIndex:0];
            range.location = range.location + 5;
            range.length = MIN(range.length - 7, (theUSSNKey.length -range.location));
            theUUID = [theUSSNKey substringWithRange:range];
            
            if (theUUID && theUUID.length > 0)
            {
                // If it is a NOTIFY - byebye message - try to find a device from a list and send him byebye
                if ([theHeaderDictionary[@"NTS"] isEqualToString:@"ssdp:byebye"])
                {
                    @synchronized (_foundServices)
                    {
                        ServiceDescription *theService = _foundServices[theUUID];

                        if (theService != nil)
                        {
                            dispatch_async(dispatch_get_main_queue(), ^
                            {
                                [self.delegate discoveryProvider:self didLoseService:theService];
                            });

                            [_foundServices removeObjectForKey:theUUID];

                            theService = nil;
                        }
                    }
                } else
                {
                    NSString *location = [theHeaderDictionary objectForKey:@"Location"];

                    if (location && location.length > 0)
                    {
                        // Advertising or search-respond
                        // Try to figure out if the device has been dicovered yet
                        ServiceDescription *foundService;
                        ServiceDescription *helloService;

                        @synchronized(_foundServices) { foundService = [_foundServices objectForKey:theUUID]; }
                        @synchronized(_helloDevices) { helloService = [_helloDevices objectForKey:theUUID]; }

                        BOOL isNew = NO;

                        // If it isn't  - create a new device object and add it to device list
                        if (foundService == nil && helloService == nil)
                        {
                            foundService = [[ServiceDescription alloc] init];
                            //Check that this is what is wanted
                            foundService.UUID = theUUID;
                            foundService.type =  theType;
                            foundService.address = anAddress;
                            foundService.port = 3001;
                            isNew = YES;
                        }

                        foundService.lastDetection = [[NSDate date] timeIntervalSince1970];

                        // If device - newly-created one notify about it's discovering
                        if (isNew)
                        {
                            @synchronized (_helloDevices)
                            {
                                if (_helloDevices == nil)
                                    _helloDevices = [NSMutableDictionary dictionary];

                                [_helloDevices setObject:foundService forKey:theUUID];
                            }

                            [self getLocationData:location forKey:theUUID andType:theType];
                        }
                    }
                }
            }
		}
	}
    
	CFRelease(theHTTPMessage);
}

- (void) getLocationData:(NSString*)url forKey:(NSString*)UUID andType:(NSString *)theType
{
    NSURL *req = [NSURL URLWithString:url];
    NSURLRequest *request = [NSURLRequest requestWithURL:req];
    [NSURLConnection sendAsynchronousRequest:request queue:_locationLoadQueue completionHandler:^(NSURLResponse *response, NSData *data, NSError *connectionError) {
        NSError *xmlError;
        NSDictionary *xml = [XMLReader dictionaryForXMLData:data error:&xmlError];

        if (!xmlError)
        {
            NSDictionary *device = [[xml objectForKey:@"root"] objectForKey:@"device"];
            NSString *friendlyName = [[device objectForKey:@"friendlyName"] objectForKey:@"text"];
            
            if (friendlyName)
            {
                BOOL hasServices = [self device:device containsServicesWithFilter:theType];
                
                if (hasServices)
                {
                    ServiceDescription *service;
                    @synchronized(_helloDevices) { service = [_helloDevices objectForKey:UUID]; }

                    service.serviceId = [self serviceIdForFilter:theType];
                    service.type = theType;
                    service.friendlyName = friendlyName;
                    service.modelName = [[device objectForKey:@"modelName"] objectForKey:@"text"];
                    service.modelNumber = [[device objectForKey:@"modelNumber"] objectForKey:@"text"];
                    service.modelDescription = [[device objectForKey:@"modelDescription"] objectForKey:@"text"];
                    service.manufacturer = [[device objectForKey:@"manufacturer"] objectForKey:@"text"];
                    service.locationXML = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                    service.commandURL = response.URL;
                    service.locationResponseHeaders = [((NSHTTPURLResponse *)response) allHeaderFields];
                    
                    @synchronized(_foundServices) { [_foundServices setObject:service forKey:UUID]; }
                    
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [self.delegate discoveryProvider:self didFindService:service];
                    });
                }
            }
        }
        
        @synchronized(_helloDevices) { [_helloDevices removeObjectForKey:UUID]; }
    }];
}

#pragma mark - Helper methods

- (BOOL) isSearchingForFilter:(NSString *)filter
{
    __block BOOL containsFilter = NO;

    [_serviceFilters enumerateObjectsUsingBlock:^(NSDictionary *serviceFilter, NSUInteger idx, BOOL *stop) {
        NSString *ssdpFilter = [[serviceFilter objectForKey:@"ssdp" ] objectForKey:@"filter"];
        
        if ([ssdpFilter isEqualToString:filter])
        {
            containsFilter = YES;
            *stop = YES;
        }
    }];
    
    return containsFilter;
}

- (BOOL)device:(NSDictionary *)device containsServicesWithFilter:(NSString *)filter
{
    __block NSArray *servicesRequired;

    [_serviceFilters enumerateObjectsUsingBlock:^(NSDictionary *serviceFilter, NSUInteger idx, BOOL *stop) {
        NSString *ssdpFilter = [[serviceFilter objectForKey:@"ssdp"] objectForKey:@"filter"];

        if ([ssdpFilter isEqualToString:filter])
        {
            servicesRequired = [[serviceFilter objectForKey:@"ssdp"] objectForKey:@"requiredServices"];
            *stop = YES;
        }
    }];

    if (!servicesRequired)
        return YES;
    
    id servicesDiscovered = [[device objectForKey:@"serviceList"] objectForKey:@"service"];
    NSMutableArray *serviceTypesDiscovered = [NSMutableArray new];
    
    void (^ssdpServiceTypeHandler)(NSDictionary *serviceObject) = ^(NSDictionary *serviceObject) {
        NSString *serviceType = [[serviceObject objectForKey:@"serviceType"] objectForKey:@"text"];
        
        if (serviceType)
            [serviceTypesDiscovered addObject:serviceType];
    };
    
    if ([servicesDiscovered isKindOfClass:[NSDictionary class]])
        ssdpServiceTypeHandler(servicesDiscovered);
    else if ([servicesDiscovered isKindOfClass:[NSArray class]])
    {
        [servicesDiscovered enumerateObjectsUsingBlock:^(NSDictionary *serviceObject, NSUInteger idx, BOOL *stop) {
            ssdpServiceTypeHandler(serviceObject);
        }];
    }
    
    if (!servicesDiscovered)
        return NO;
    
    __block BOOL deviceHasAllServices = YES;
    
    [servicesRequired enumerateObjectsUsingBlock:^(NSString *service, NSUInteger idx, BOOL *stop) {
        if (![serviceTypesDiscovered containsObject:service])
        {
            deviceHasAllServices = NO;
            *stop = YES;
        }
    }];
    
    return deviceHasAllServices;
}

- (NSString *) serviceIdForFilter:(NSString *)filter
{
    __block NSString *serviceId;
    
    [_serviceFilters enumerateObjectsUsingBlock:^(NSDictionary *serviceFilter, NSUInteger idx, BOOL *stop) {
        NSString *ssdpFilter = [[serviceFilter objectForKey:@"ssdp"] objectForKey:@"filter"];
        
        if ([ssdpFilter isEqualToString:filter])
        {
            serviceId = [serviceFilter objectForKey:@"serviceId"];
            *stop = YES;
        }
    }];
    
    return serviceId;
}

- (void) performBlock:(void (^)())block afterDelay:(NSTimeInterval)delay
{
    [self performSelector:@selector(performBlock:) withObject:block afterDelay:delay];
}

- (void) performBlock:(void (^)())block
{
    if (block)
        block();
}

- (NSString *) userAgentForToken:(NSString *)token
{
    if (!token)
        token = @"UPnP/1.1";

    return [NSString stringWithFormat:
            @"%@/%@ %@ ConnectSDK/%@",
            [UIDevice currentDevice].systemName,
            [UIDevice currentDevice].systemVersion,
            token,
            @(CONNECT_SDK_VERSION)];
}

@end
