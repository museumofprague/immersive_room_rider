# Imerssive room Museum of Prague
We are providing technical details for audio visual content for the immersive room at Museum of Prague main building at Florenc, Prague, Czech Republic. 

## Video
We are using Pixera media server for projector blending and synchronization. No need to create videomapping, just pass your clean video to Pixera server.

* one wall: 9974x1929px
* floor: 6830 x 2160px
* 10bit 4:2:2 YcBcR
* video codec HAP / NochLC

Output three NDI streams from your app - one for each wall, one for floor. We can also mirror the content to other walls / floor (for example you can output just single stream for walls and one for floor if you don't mind same video on both walls). 

### How to record video

Download NewTek SHQ7 codec:
https://www.vizrt.com/support/product-updates/codecs-utilities/newtek-codec-for-windows/

Download NDI Tools:
https://ndi.video/tools/

Output NDI stream from your application, use NDI Tools Studio Monitor to save the stream to disk. Use ffmpeg to convert from SHQ7 codec to HAP. Send us video in HAP format.

## Audio
We have 12.4 speaker layout but we are effectively using 12.1 (all 4 subwoofers are fed from single audio source).
