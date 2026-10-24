#include <libavformat/avformat.h>
#include <libavutil/error.h>
#include <stdio.h>
#include <stdlib.h>
static void require(int result,const char *operation){if(result<0){char text[AV_ERROR_MAX_STRING_SIZE];av_strerror(result,text,sizeof(text));fprintf(stderr,"%s: %s\n",operation,text);exit(1);}}
int main(int argc,char **argv){
    if(argc!=3)return 2;AVFormatContext *input=NULL,*output=NULL;
    require(avformat_open_input(&input,argv[1],NULL,NULL),"open fixture");require(avformat_find_stream_info(input,NULL),"read streams");
    char playlist[4096],segments[4096];snprintf(playlist,sizeof(playlist),"%s/index.m3u8",argv[2]);snprintf(segments,sizeof(segments),"%s/segment-%%03d.ts",argv[2]);
    require(avformat_alloc_output_context2(&output,NULL,"hls",playlist),"create HLS");
    for(unsigned int i=0;i<input->nb_streams;i++){AVStream *stream=avformat_new_stream(output,NULL);if(!stream)return 3;require(avcodec_parameters_copy(stream->codecpar,input->streams[i]->codecpar),"copy parameters");stream->codecpar->codec_tag=0;stream->time_base=input->streams[i]->time_base;}
    AVDictionary *options=NULL;av_dict_set(&options,"hls_time","2",0);av_dict_set(&options,"hls_list_size","0",0);av_dict_set(&options,"hls_playlist_type","vod",0);av_dict_set(&options,"hls_segment_filename",segments,0);
    require(avformat_write_header(output,&options),"HLS header");av_dict_free(&options);
    AVPacket *packet=av_packet_alloc();int result;
    while((result=av_read_frame(input,packet))>=0){int index=packet->stream_index;av_packet_rescale_ts(packet,input->streams[index]->time_base,output->streams[index]->time_base);packet->pos=-1;require(av_interleaved_write_frame(output,packet),"HLS packet");av_packet_unref(packet);}
    if(result!=AVERROR_EOF)require(result,"read packet");require(av_write_trailer(output),"HLS trailer");av_packet_free(&packet);avformat_free_context(output);avformat_close_input(&input);return 0;
}
