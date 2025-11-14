# Imerssive room Museum of Prague
We are providing technical details for audio visual content for the immersive room at Museum of Prague main building at Florenc, Prague, Czech Republic. 

## Video
We are using [Pixera media server](https://pixera.one/en/) for projector blending and synchronization. No need to create videomapping, just pass your clean video to Pixera server.

* one wall: 9974x1929px
* floor: 6830 x 2160px
* 10bit 4:2:2 YcBcR
* video codec HAP / NochLC
* accepts NDI streams

Output three NDI streams from your app - one for each wall, one for floor. We can also mirror the content to other walls / floor (for example you can output just single stream for walls and one for floor if you don't mind same video on both walls). 

In case you can't output NDI, you can use Spout:
* https://spout.zeal.co/
We provide Spout to NDI proxy to send the Spout texture to Media server. 

### Pre-render video

#### Capture NDI / Spout stream

##### NDI Tools
You can download [NDI Tools](https://ndi.video/tools/). NDI Tools should already include the [NewTek SHQ7 codec]([https://pixera.one/en/](https://www.vizrt.com/support/product-updates/codecs-utilities/newtek-codec-for-windows/)). Output NDI stream from your application, use NDI Tools Studio Monitor to save the stream to disk (it will save it in .mov SHQ7 codec).

Unfortunetly, FFmpeg’s built-in SpeedHQ decoder does NOT support SHQ7 (YUVA422P with alpha, 10-bit-ish NewTek variant). So altought you can encode to HAP with ffmpeg, you can't decode .mov SHQ7 saved from NDI Tools Studio Monitor. For that you will need 3rd party paid plugin such as AfterCodecs for AE. 

##### OBS
You can use free [OBS software](https://obsproject.com/) along with [NDI plugin for OBS](https://github.com/DistroAV/DistroAV/releases) to record NDI streams. Better yet, OBS also supports the direct Spout capture. Unfortunetly, you might be limited by avaliable max resolution inside OBS based on current diplay setting and GPU.

##### Spout Recording only
* Another option is to use [LightJams Spout recorder](https://www.lightjams.com/spout-recorder.html) for capturing Spout stream. 
* One more worth looking into is open source [SpoutRecorder](https://github.com/leadedge/SpoutRecorder/). 

#### Convert Video to HAP codec

##### Ffmpeg
HAP codec can be included in ffmpeg build or using 3rd party paid plugins such as AfterCodecs for Adobe After Effects. See more [here](https://hap.video/using-hap.html).

On Windows you can check if your current ffmpeg build support HAP codec with  `ffmpeg -encoders | findstr /i hap`. Example terminal output on Windows: `V.S..D hap  Vidvox Hap`. Or on Linux / MacOS you can check with `ffmpeg -encoders | grep hap`. To converrt the video to HAP use command `ffmpeg -i input.mov -c:v hap output.mov` or `ffmpeg -i yourSourceFile.mov -c:v hap -format hap_q outputName.mov`.

To solve uneven resolution:  `ffmpeg -i test.mp4 -vf "scale=6828:2160" -c:v hap -format hap_q -c:a aac testhap.mov` You need to target resolution divisible by 4 (ie 28 or 32). 

## Audio
We have 12.4 2D speaker layout but we are effectively using 12.1 (all 4 subwoofers are fed from single audio source). 
Speaker positions are provided in normalized coordinates from -1 to +1 with a centroid at (0,0). 
* [speaker_layout](https://github.com/museumofprague/immersive_room_rider/blob/main/speaker_preset/muzeum_prahy.json) 

We can provide you with spatial audio realtime engine. The system expects OSC messages with virtual audio sources positions and it will calculate needed volumes for all speakers to create an illusion of the sound coming from given direction. 

## Dimensions
6.998 * 18 meters

## Templates
WIP

* Touchdesigner
* Processing


#### Notes
* [Java Wrapper for NDI](https://github.com/WalkerKnapp/devolay)