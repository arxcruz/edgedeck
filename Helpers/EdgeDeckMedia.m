// Now-playing bridge for EdgeDeck.
//
// MediaRemote (the private framework behind Control Center's Now Playing) only
// answers Apple-signed clients on recent macOS. EdgeDeck therefore loads this
// library into /usr/bin/perl (com.apple.perl) and talks to it over pipes:
//
//   stdout: one JSON object per line whenever now-playing state changes
//   stdin:  commands, one per line: play | pause | toggle | next | previous | seek <seconds>
//
// The process exits when stdin closes (i.e. when EdgeDeck quits).

#import <Foundation/Foundation.h>
#import <dlfcn.h>

typedef void (*MRGetInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRGetBool)(dispatch_queue_t, void (^)(Boolean));
typedef void (*MRGetPID)(dispatch_queue_t, void (^)(int));
typedef void (*MRRegister)(dispatch_queue_t);
typedef Boolean (*MRSendCommand)(int, NSDictionary *);
typedef void (*MRSetElapsed)(double);

static MRGetInfo getInfo;
static MRGetBool getIsPlaying;
static MRGetPID getPID;
static MRSendCommand sendCommand;
static MRSetElapsed setElapsed;
static NSString *lastLine;

// MRMediaRemoteCommand values.
enum { kPlay = 0, kPause = 1, kToggle = 2, kNext = 4, kPrevious = 5 };

static id value(NSDictionary *info, NSString *suffix) {
    return info[[@"kMRMediaRemoteNowPlayingInfo" stringByAppendingString:suffix]];
}

static void emit(void) {
    getInfo(dispatch_get_main_queue(), ^(NSDictionary *info) {
        getIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
            getPID(dispatch_get_main_queue(), ^(int pid) {
                NSMutableDictionary *out = [NSMutableDictionary dictionary];
                out[@"playing"] = @(playing);
                out[@"pid"] = @(pid);
                for (NSString *key in @[@"Title", @"Artist", @"Album", @"ArtworkIdentifier", @"ContentItemIdentifier"]) {
                    id v = value(info, key);
                    if ([v isKindOfClass:[NSString class]] && [v length]) out[[key lowercaseString]] = v;
                }
                for (NSString *key in @[@"Duration", @"ElapsedTime", @"PlaybackRate"]) {
                    id v = value(info, key);
                    if ([v isKindOfClass:[NSNumber class]]) out[[key lowercaseString]] = v;
                }
                NSDate *timestamp = value(info, @"Timestamp");
                if ([timestamp isKindOfClass:[NSDate class]]) out[@"timestamp"] = @([timestamp timeIntervalSince1970]);
                NSData *artwork = value(info, @"ArtworkData");
                if ([artwork isKindOfClass:[NSData class]] && artwork.length) out[@"artwork"] = [artwork base64EncodedStringWithOptions:0];

                NSData *json = [NSJSONSerialization dataWithJSONObject:out options:NSJSONWritingSortedKeys error:nil];
                NSString *line = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
                if (!line || [line isEqualToString:lastLine]) return;
                lastLine = line;
                fprintf(stdout, "%s\n", line.UTF8String);
                fflush(stdout);
            });
        });
    });
}

static void handle(NSString *command) {
    NSArray<NSString *> *parts = [command componentsSeparatedByString:@" "];
    NSString *name = parts.firstObject;
    if ([name isEqualToString:@"play"]) sendCommand(kPlay, nil);
    else if ([name isEqualToString:@"pause"]) sendCommand(kPause, nil);
    else if ([name isEqualToString:@"toggle"]) sendCommand(kToggle, nil);
    else if ([name isEqualToString:@"next"]) sendCommand(kNext, nil);
    else if ([name isEqualToString:@"previous"]) sendCommand(kPrevious, nil);
    else if ([name isEqualToString:@"seek"] && parts.count > 1) setElapsed(parts[1].doubleValue);
    else if ([name isEqualToString:@"refresh"]) lastLine = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{ emit(); });
}

// Called from perl as an XSUB; the perl interpreter arguments are ignored. Never returns.
void edgedeck_media_run(void *perl, void *cv) {
    void *mr = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (MRGetInfo)dlsym(mr, "MRMediaRemoteGetNowPlayingInfo");
    getIsPlaying = (MRGetBool)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    getPID = (MRGetPID)dlsym(mr, "MRMediaRemoteGetNowPlayingApplicationPID");
    sendCommand = (MRSendCommand)dlsym(mr, "MRMediaRemoteSendCommand");
    setElapsed = (MRSetElapsed)dlsym(mr, "MRMediaRemoteSetElapsedTime");
    MRRegister registerForNotifications = (MRRegister)dlsym(mr, "MRMediaRemoteRegisterForNowPlayingNotifications");
    if (!getInfo || !getIsPlaying || !getPID || !sendCommand || !setElapsed || !registerForNotifications) {
        fprintf(stderr, "EdgeDeckMedia: MediaRemote symbols unavailable\n");
        exit(2);
    }

    registerForNotifications(dispatch_get_main_queue());
    for (NSString *name in @[@"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
                             @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [[NSNotificationCenter defaultCenter] addObserverForName:name object:nil queue:nil
                                                      usingBlock:^(NSNotification *note) { emit(); }];
    }

    // Safety net in case a notification is missed; identical states aren't re-sent.
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC, NSEC_PER_SEC);
    dispatch_source_set_event_handler(timer, ^{ emit(); });
    dispatch_resume(timer);

    __block NSMutableData *buffer = [NSMutableData data];
    dispatch_source_t input = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(input, ^{
        char chunk[1024];
        ssize_t n = read(STDIN_FILENO, chunk, sizeof chunk);
        if (n <= 0) exit(0);
        [buffer appendBytes:chunk length:n];
        NSString *text = [[NSString alloc] initWithData:buffer encoding:NSUTF8StringEncoding] ?: @"";
        NSArray<NSString *> *lines = [text componentsSeparatedByString:@"\n"];
        buffer = [[lines.lastObject dataUsingEncoding:NSUTF8StringEncoding] mutableCopy];
        for (NSUInteger i = 0; i + 1 < lines.count; i++) {
            NSString *line = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            if (line.length) handle(line);
        }
    });
    dispatch_resume(input);

    // Keep the sources alive for the life of the process.
    static dispatch_source_t keep[2];
    keep[0] = timer;
    keep[1] = input;
    dispatch_main();
}
