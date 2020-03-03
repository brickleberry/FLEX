//
//  FLEXSystemLogViewController.m
//  FLEX
//
//  Created by Ryan Olson on 1/19/15.
//  Copyright (c) 2015 f. All rights reserved.
//

#import "FLEXSystemLogViewController.h"
#import "FLEXASLLogController.h"
#import "FLEXOSLogController.h"
#import "FLEXSystemLogCell.h"
#import "FLEXUtility.h"
#import "FLEXColor.h"
#import "FLEXResources.h"
#import "UIBarButtonItem+FLEX.h"
#import "fishhook.h"
#import <dlfcn.h>

@interface FLEXSystemLogViewController ()

@property (nonatomic, readonly) id<FLEXLogController> logController;
@property (nonatomic, readonly) NSMutableArray<FLEXSystemLogMessage *> *logMessages;
@property (nonatomic, copy) NSArray<FLEXSystemLogMessage *> *filteredLogMessages;

@end

static void (*MSHookFunction)(void *symbol, void *replace, void **result);

static BOOL FLEXDidHookNSLog = NO;
static BOOL FLEXNSLogHookWorks = NO;
BOOL (*orig_os_log_shim_enabled)() = nil;
BOOL my_os_log_shim_enabled() {
    return NO;
}

extern BOOL os_log_shim_enabled();

@implementation FLEXSystemLogViewController

+ (void)load {
    // Thanks to @Ram4096 on GitHub for telling me that
    // os_log is conditionally enabled by the SDK version
    FLEXDidHookNSLog = rebind_symbols((struct rebinding[1]) {
        "os_log_shim_enabled",
        (void *)my_os_log_shim_enabled,
        (void **)&orig_os_log_shim_enabled
    }, 1) == 0;
    
    if (FLEXDidHookNSLog && orig_os_log_shim_enabled != nil) {
        // Check if our rebinding worked
        FLEXNSLogHookWorks = os_log_shim_enabled() == NO;
    }
    
    // So, just because we rebind the lazily loaded symbol for
    // this function doesn't mean it's even going to be used.
    // While it seems to be sufficient for the simulator, for
    // whatever reason it is not sufficient on-device. We need
    // to actually hook the function with something like Substrate.
    
    // Check if we have substrate, and if so use that instead
    void *handle = dlopen("/usr/lib/libsubstrate.dylib", RTLD_LAZY);
    if (handle) {
        MSHookFunction = dlsym(handle, "MSHookFunction");
        
        if (MSHookFunction) {
            // Set the hook and check if it worked
            //
            // Very important that we use orig_os_log_shim_enabled
            // here as opposed to os_log_shim_enabled.
            MSHookFunction(orig_os_log_shim_enabled, my_os_log_shim_enabled, nil);
            FLEXNSLogHookWorks = orig_os_log_shim_enabled() == NO;
            if (FLEXNSLogHookWorks) {
                return;
            }
        }
    }
}

- (id)init {
    return [super initWithStyle:UITableViewStylePlain];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.showsSearchBar = YES;

    __weak __typeof(self) weakSelf = self;
    id logHandler = ^(NSArray<FLEXSystemLogMessage *> *newMessages) {
        __strong __typeof(weakSelf) self = weakSelf;
        [self handleUpdateWithNewMessages:newMessages];
    };

    _logMessages = [NSMutableArray array];
    if (FLEXOSLogAvailable() && !FLEXNSLogHookWorks) {
        _logController = [FLEXOSLogController withUpdateHandler:logHandler];
    } else {
        _logController = [FLEXASLLogController withUpdateHandler:logHandler];
    }

    [self.tableView registerClass:[FLEXSystemLogCell class] forCellReuseIdentifier:kFLEXSystemLogCellIdentifier];
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleNone;
    self.title = @"Loading...";
    
    // Toolbar buttons //
    
    UIBarButtonItem *scrollDown = [UIBarButtonItem
        itemWithImage:FLEXResources.scrollToBottomIcon
        target:self
        action:@selector(scrollToLastRow)
    ];
    UIBarButtonItem *settings = [UIBarButtonItem
        itemWithImage:FLEXResources.gearIcon
        target:self
        action:@selector(showLogSettings)
    ];
    
    if (FLEXOSLogAvailable() && !FLEXNSLogHookWorks) {
        [self addToolbarItems:@[scrollDown, settings]];
    } else {
        [self addToolbarItems:@[scrollDown]];
    }
}

- (void)handleUpdateWithNewMessages:(NSArray<FLEXSystemLogMessage *> *)newMessages {
    self.title = @"System Log";

    [self.logMessages addObjectsFromArray:newMessages];

    // "Follow" the log as new messages stream in if we were previously near the bottom.
    BOOL wasNearBottom = self.tableView.contentOffset.y >= self.tableView.contentSize.height - self.tableView.frame.size.height - 100.0;
    [self.tableView reloadData];
    if (wasNearBottom) {
        [self scrollToLastRow];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];

    [self.logController startMonitoring];
}

- (void)scrollToLastRow {
    NSInteger numberOfRows = [self.tableView numberOfRowsInSection:0];
    if (numberOfRows > 0) {
        NSIndexPath *lastIndexPath = [NSIndexPath indexPathForRow:numberOfRows - 1 inSection:0];
        [self.tableView scrollToRowAtIndexPath:lastIndexPath atScrollPosition:UITableViewScrollPositionBottom animated:YES];
    }
}

- (void)showLogSettings {
    FLEXOSLogController *logController = (FLEXOSLogController *)self.logController;
    BOOL persistent = [[NSUserDefaults standardUserDefaults] boolForKey:kFLEXiOSPersistentOSLogKey];
    NSString *toggle = persistent ? @"Disable" : @"Enable";
    NSString *title = [@"Persistent logging: " stringByAppendingString:persistent ? @"ON" : @"OFF"];
    NSString *body = @"In iOS 10 and up, ASL is gone. The OS Log API is much more limited. "
    "To get as close to the old behavior as possible, logs must be collected manually at launch and stored.\n\n"
    "Turn this feature on only when you need it.";

    [FLEXAlert makeAlert:^(FLEXAlert *make) {
        make.title(title).message(body).button(toggle).handler(^(NSArray<NSString *> *strings) {
            [[NSUserDefaults standardUserDefaults] setBool:!persistent forKey:kFLEXiOSPersistentOSLogKey];
            logController.persistent = !persistent;
            [logController.messages addObjectsFromArray:self.logMessages];
        });
        make.button(@"Dismiss").cancelStyle();
    } showFrom:self];
}


#pragma mark - FLEXGlobalsEntry

+ (NSString *)globalsEntryTitle:(FLEXGlobalsRow)row {
    return @"⚠️  System Log";
}

+ (UIViewController *)globalsEntryViewController:(FLEXGlobalsRow)row {
    return [self new];
}


#pragma mark - Table view data source

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return self.searchController.isActive ? self.filteredLogMessages.count : self.logMessages.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath  {
    FLEXSystemLogCell *cell = [tableView dequeueReusableCellWithIdentifier:kFLEXSystemLogCellIdentifier forIndexPath:indexPath];
    cell.logMessage = [self logMessageAtIndexPath:indexPath];
    cell.highlightedText = self.searchText;
    
    if (indexPath.row % 2 == 0) {
        cell.backgroundColor = [FLEXColor primaryBackgroundColor];
    } else {
        cell.backgroundColor = [FLEXColor secondaryBackgroundColor];
    }
    
    return cell;
}

- (CGFloat)tableView:(UITableView *)tableView heightForRowAtIndexPath:(NSIndexPath *)indexPath {
    FLEXSystemLogMessage *logMessage = [self logMessageAtIndexPath:indexPath];
    return [FLEXSystemLogCell preferredHeightForLogMessage:logMessage inWidth:self.tableView.bounds.size.width];
}


#pragma mark - Copy on long press

- (BOOL)tableView:(UITableView *)tableView shouldShowMenuForRowAtIndexPath:(NSIndexPath *)indexPath {
    return YES;
}

- (BOOL)tableView:(UITableView *)tableView canPerformAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender {
    return action == @selector(copy:);
}

- (void)tableView:(UITableView *)tableView performAction:(SEL)action forRowAtIndexPath:(NSIndexPath *)indexPath withSender:(id)sender {
    if (action == @selector(copy:)) {
        // We usually only want to copy the log message itself, not any metadata associated with it.
        UIPasteboard.generalPasteboard.string = [self logMessageAtIndexPath:indexPath].messageText;
    }
}

- (FLEXSystemLogMessage *)logMessageAtIndexPath:(NSIndexPath *)indexPath {
    return self.searchController.isActive ? self.filteredLogMessages[indexPath.row] : self.logMessages[indexPath.row];
}


#pragma mark - Search bar

- (void)updateSearchResults:(NSString *)searchString {
    [self onBackgroundQueue:^NSArray *{
        return [self.logMessages filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(FLEXSystemLogMessage *logMessage, NSDictionary<NSString *, id> *bindings) {
            NSString *displayedText = [FLEXSystemLogCell displayedTextForLogMessage:logMessage];
            return [displayedText rangeOfString:searchString options:NSCaseInsensitiveSearch].length > 0;
        }]];
    } thenOnMainQueue:^(NSArray *filteredLogMessages) {
        if ([self.searchText isEqual:searchString]) {
            self.filteredLogMessages = filteredLogMessages;
            [self.tableView reloadData];
        }
    }];
}

@end
