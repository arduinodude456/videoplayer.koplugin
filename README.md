# videoplayer.koplugin
YAYY! A KOReader Plugin to watch Videos (with sound). Fast on EInk Devices. Plss read the README

# What this plugin can do, what it can't(right now)
## Play Videos
This plugin can play videos in the .bwr format. You can use make.py in the "tools" folder to build them from mp4.
**I recommend you to set the FPS to 7.5, not more not less, but my Kobo Libra Colour works well with 30(!) FPS even then the audio isn't that sync.**
## Play audio and Video
If you wanna hear audio, you have to connect a bluetooth speaker. On non-bluetooth devices the plugin falls back to internal speaker. But this isn't tested right now. 
The Audio is built as a seperate WAV file by the Python script, and you have to copy it to the reader. into the exact same dir where the video is. Videos without WAV will cause a warning about that the WAV file isnt there.
## What it looks like
Color rendering is not supported currently, but I want to add in future. You have to know that screen refreshes aare expensive for the time, so I turned out to use only Black and White, no grayscale, so the display refreshes faster. Dithering is used to make the grayscale. In future, this will be extended to colordithering (rgb), but I think it should be possible to turn this off cause it takes too much memory on b/w displays.

# Additional
Videos are faster and more beautiful if you **turn off color rendering in KOReader settings**.
