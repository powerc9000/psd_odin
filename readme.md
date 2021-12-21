# PSD Odin

PSD parser in pure Odin. With many thanks for the intial code from jharler.

## Features
- Parse PSD layer info.
	- Layer Name
	- Layer id
	- Group
	- Blending mode
	 
- Get PSD layer image data as byte array
	- Handles 3 channel and 3 + alpha layers
	- Correctly decodes RLE layers
	- Merged RGBA layers into single R8G8B8A8 byte array of pixels.

## Useage

### Parse the PSD.

	```odin
		psd_info := psd_odin.load_file_from_memory(fileData);
	```
	
### Extract image data

Now the PSD has layer info and document info. Crucially this step doesnt parse all the image data. Do this as a seperate call per layer.


```odin
	for layer in psd_info.layers {
		// file data is the byte array of the file from disk.
		psd_odin.psd_create_layer_image(layer, psd_info.file_header.height_in_pixels, psd_info.file_header.height_in_pixels, fileData);
	}

```

The layer will now have its `.composited_image` slice populated with the pixel array.

This library doesn't handle blending layers together.

