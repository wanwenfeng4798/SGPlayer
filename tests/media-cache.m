#import <Foundation/Foundation.h>
#import "SGMediaCache.h"
#define VERIFY(x) do{if(!(x)){fprintf(stderr,"FAIL %s:%d %s\n",__FILE__,__LINE__,#x);exit(1);}}while(0)
static void Await(BOOL (^finished)(void)) {
    NSDate *limit=[NSDate dateWithTimeIntervalSinceNow:15];
    while(!finished()&&limit.timeIntervalSinceNow>0)[NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.01]];
    VERIFY(finished());
}
static NSURL *Download(SGMediaCache *cache,NSURLRequest *request,NSString *hash,NSError **error) {
    __block BOOL done=NO;__block NSURL *result=nil;__block NSError *failure=nil;
    [cache downloadRequest:request expectedSHA256:hash progress:^(int64_t received,int64_t expected){VERIFY(NSThread.isMainThread);VERIFY(received>0);} completion:^(NSURL *URL,NSError *problem){VERIFY(NSThread.isMainThread);result=URL;failure=problem;done=YES;}];
    Await(^BOOL{return done;});if(error)*error=failure;return result;
}
int main(int argc,const char *argv[]) {
    @autoreleasepool{
        VERIFY(argc==3);NSURL *base=[NSURL URLWithString:[NSString stringWithUTF8String:argv[1]]];NSURL *directory=[NSURL fileURLWithPath:[NSString stringWithUTF8String:argv[2]]];
        NSError *error=nil;SGMediaCache *cache=[[SGMediaCache alloc]initWithDirectory:directory maximumBytes:96*1024 error:&error];VERIFY(cache&&!error);
        NSURLRequest *(^request)(NSString *)=^NSURLRequest *(NSString *path){return [NSURLRequest requestWithURL:[NSURL URLWithString:path relativeToURL:base]];};
        NSURLRequest *a=request(@"a.bin"),*b=request(@"b.bin");
        NSURL *local=Download(cache,a,nil,&error);VERIFY(local&&!error&&cache.cachedBytes==65536);NSData *original=[NSData dataWithContentsOfURL:local];VERIFY(original.length==65536);
        VERIFY([cache pinRequest:a]);VERIFY(!Download(cache,b,nil,&error)&&error);VERIFY([cache cachedURLForRequest:a]);
        [cache unpinRequest:a];VERIFY(Download(cache,b,nil,&error)&&!error);VERIFY(![cache cachedURLForRequest:a]);VERIFY(cache.cachedBytes<=cache.maximumBytes);
        [cache removeAllUnpinned];NSURLRequest *movie=request(@"movie.mp4");NSURL *movieFile=Download(cache,movie,nil,&error);VERIFY(movieFile&&[movieFile.pathExtension isEqual:@"mp4"]);
        [cache close];cache=[[SGMediaCache alloc]initWithDirectory:directory maximumBytes:96*1024 error:&error];VERIFY([cache cachedURLForRequest:movie]);
        [cache removeAllUnpinned];VERIFY(Download(cache,b,nil,&error));
        NSURL *validB=[cache cachedURLForRequest:b];NSData *before=[NSData dataWithContentsOfURL:validB];
        VERIFY(!Download(cache,b,[@"0" stringByPaddingToLength:64 withString:@"0" startingAtIndex:0],&error)&&error);
        VERIFY([[NSData dataWithContentsOfURL:validB] isEqual:before]);
        for(NSString *path in @[@"404.bin",@"partial.bin",@"huge.bin",@"index.m3u8",@"disguised.bin"]){VERIFY(!Download(cache,request(path),nil,&error)&&error);VERIFY(![cache cachedURLForRequest:request(path)]);}
        // Request identity includes authorization. A second account cannot receive the first account's file.
        [cache removeAllUnpinned];NSMutableURLRequest *privateA=[request(@"private.bin") mutableCopy],*privateB=[privateA mutableCopy];
        [privateA setValue:@"Bearer account-A" forHTTPHeaderField:@"Authorization"];[privateB setValue:@"Bearer account-B" forHTTPHeaderField:@"Authorization"];
        VERIFY(Download(cache,privateA,nil,&error));VERIFY(![cache cachedURLForRequest:privateB]);
        // An active duplicate reports an error; cancellation reports once, and cannot publish a partial file.
        __block BOOL cancelled=NO,duplicate=NO;NSURLRequest *slow=request(@"slow.bin");
        NSUUID *identifier=[cache downloadRequest:slow expectedSHA256:nil progress:nil completion:^(NSURL *URL,NSError *failure){VERIFY(!URL&&failure);cancelled=YES;}];VERIFY(identifier);
        VERIFY(![cache downloadRequest:slow expectedSHA256:nil progress:nil completion:^(NSURL *URL,NSError *failure){VERIFY(!URL&&failure);duplicate=YES;}]);
        [cache cancelDownload:identifier];Await(^BOOL{return cancelled&&duplicate;});VERIFY(![cache cachedURLForRequest:slow]);
        [cache close];VERIFY(!Download(cache,a,nil,&error)&&error);
        puts("PASS cache download/quota/pins/LRU/checksum/HTTP partial/error/manifest/auth isolation/duplicate/cancel/close");
    }return 0;
}
