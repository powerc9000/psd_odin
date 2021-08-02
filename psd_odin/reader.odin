package psd

/*
* Adobe PSD Format:
* https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/
*
* This is a bare-bones parser with the intention of being able to grab the
* image data on a per-layer basis and an overall basis.
* 
*/

import "core:mem"
import "core:unicode/utf16";
import "core:fmt"
import "core:log"
import "core:os"
import "core:strings"
import "core:runtime";

Psd_File_Header :: struct #packed {
	signature        : [4]byte,
	version          : u16be,
	reserved         : [6]byte,
	num_channels     : u16be,
	height_in_pixels : u32be,
	width_in_pixels  : u32be,
	depth            : u16be,
	color_mode       : Psd_Color_Mode,
}

Psd_Color_Mode :: enum u16be {
	Bitmap       = 0,
	Grayscale    = 1,
	Indexed      = 2,
	RGB          = 3,
	CMYK         = 4,
	Multichannel = 7,
	Duotone      = 8,
	Lab          = 9,
}

Psd_File_Info :: struct {
	file_header             : Psd_File_Header,
	image_resources         : [dynamic] Psd_Image_Resource,
	layers                  : [dynamic] Psd_Layer_Info,
	first_layer_transparent : bool,
	composited_image        : []byte,
}


Psd_Image_Resource :: struct {
	unique_id : u16,
	name      : string,
	data      : []byte,
}


Psd_Layer_Info :: struct {
	id               : i32be,
	name             : string,
	group_path       : string,
	group            : bool,
	dimensions       : Psd_Dimensions,
	channel_count    : i16be,
	channel_info     : []Psd_Channel_Info,
	channel_images   : [dynamic]Psd_Channel_Image,
	layer_record     : Psd_Layer_Record,
	composited_image : []byte,
	transparentMask  : Psd_Dimensions,
	hasMask          : bool

}

Psd_Dimensions :: struct {
	top, left, bottom, right : i32be,
}

Psd_Channel_Info :: struct #packed {
	id   : i32,
	data : u32,
	offset : u64
}

Psd_Channel_Image :: struct {
	image_data : []byte,
}

Psd_Layer_Record :: struct #packed {
	blend_mode_key       : [4]byte,
	opacity              : byte,
	clipping             : byte,
	flags                : byte,
	filler               : byte,
	extra_data_field_len : u32be,
};

// ----------------------------------------------------------------------------

psd_file_load :: proc {psd_file_load_from_disk, psd_file_load_from_memory};

// ----------------------------------------------------------------------------

psd_file_load_from_disk :: proc (file_name : string) -> (Psd_File_Info, bool) {
	file_data, read_ok := os.read_entire_file(file_name);
	fmt.println(read_ok);
	if !read_ok do return {}, false;
	file_info, file_ok := psd_file_load_from_memory(file_data);
	delete(file_data);
	return file_info, file_ok;
}

// ----------------------------------------------------------------------------

psd_file_load_from_memory :: proc (file_data : []byte) -> (Psd_File_Info, bool) {
	file_info : Psd_File_Info;

	current_pos : u32 = 0;

	needs_cleanup := true;
	defer if needs_cleanup {
		psd_file_cleanup(&file_info);
	}

	// header
	if header_ok := _read_from_buffer(mem.ptr_to_bytes(&file_info.file_header), file_data, &current_pos); !header_ok {
		_psd_log_error("error reading PSD file header");
		return {}, false;
	}

	_psd_log(file_info.file_header);
	if !_psd_verify_header(&file_info.file_header) {
		fmt.println("couldn't verify header");
		return {}, false;
	}

	// color mode
	if !_psd_read_color_mode_data(&file_info, file_data, &current_pos) {
		fmt.println("couldn't load color mode");
		return {}, false;
	}

	// image resources
	if !_psd_read_image_resources_data(&file_info, file_data, &current_pos) {
		fmt.println("couldn't read resourced");
		return {}, false;
	}

	if !_psd_read_layer_and_mask_data(&file_info, file_data, &current_pos) {
		fmt.println("couldn't load layers");
		return {}, false;
	}
	/*
	if !_psd_read_image_data(&file_info, file_data, &current_pos) {
		return {}, false;
	}
	*/


	needs_cleanup = false;

	return file_info, true;
}

// ----------------------------------------------------------------------------

psd_file_cleanup :: proc (psd_file : ^Psd_File_Info) {
	for layer in psd_file.layers {
		for image in layer.channel_images {
			delete(image.image_data);
		}
		delete(layer.channel_images);
		delete(layer.channel_info);
		delete(layer.composited_image);
		delete(layer.name);
	}
	delete(psd_file.layers);
	delete(psd_file.composited_image);
}

// ----------------------------------------------------------------------------

_psd_verify_header :: proc (file_header : ^Psd_File_Header) -> bool {
	// verify signature
	if strings.string_from_ptr(&file_header.signature[0], len(file_header.signature)) != "8BPS" {
		_psd_log_error("file does not contain proper PSD signature");
		return false;
	}

	// verify version
	if file_header.version != 1 {
		_psd_log_error("file does not contain proper PSD version");
		return false;
	}

	for r in file_header.reserved {
		if r != 0 {
			_psd_log_error("file does not contain proper PSD reserved data");
			return false;
		}
	}

	return true;	
}

// ----------------------------------------------------------------------------

_psd_read_color_mode_data :: proc(file_info : ^Psd_File_Info, file_data: []byte, current_pos: ^u32) -> bool {
	color_mode_len : u32be;
	if color_mode_len_ok := _read_from_buffer(mem.ptr_to_bytes(&color_mode_len), file_data, current_pos); !color_mode_len_ok {
		_psd_log_error("error reading PSD color mode");
		return false;
	}

	_psd_log("color_mode_len = ", color_mode_len);
	if file_info.file_header.color_mode == .Indexed {
		if color_mode_len != 768  {
			_psd_log_error("color mode data does not match indexes color mode");
			return false;
		}
	}
	else if file_info.file_header.color_mode == .Duotone {
		// do nothing
	}
	else {
		if color_mode_len > 0 {
			_psd_log_error("unexpected color mode data encountered");
			return false;
		}
	}

	current_pos^ += u32(color_mode_len);
	return true;
}

// ----------------------------------------------------------------------------

_psd_read_image_resources_data :: proc(file_info : ^Psd_File_Info, file_data: []byte, current_pos: ^u32) -> bool {
	image_rs_len : u32be;
	if !_read_from_buffer(mem.ptr_to_bytes(&image_rs_len), file_data, current_pos) do return _report_error("unable to read image resource section length");

	image_rs_start_pos := current_pos^;

	for {
		signature : [4]byte;
		if !_read_from_buffer(signature[:], file_data, current_pos) do return _report_error("unable to read image resource signature");

		signature_str := strings.string_from_ptr(&signature[0], len(signature));
		if signature_str != "8BIM" do return _report_error("image resource signature mismatch. ", signature_str);

		unique_id : u16be;
		if !_read_from_buffer(mem.ptr_to_bytes(&unique_id), file_data, current_pos) do return _report_error("unable to read image resource unique id");

		name_len: byte;
		if !_read_from_buffer(mem.ptr_to_bytes(&name_len), file_data, current_pos) do return _report_error("unable to read image resource name length");

		if name_len > 0 {
			name : [256]byte;
			if !_read_from_buffer(name[:name_len], file_data, current_pos) do return _report_error("unable to read image resource name");
			_psd_log("name = ", name);
		}
		else {
			current_pos^ += 1; // null name consists of 2 bytes
		}

		data_len : u32be;
		if !_read_from_buffer(mem.ptr_to_bytes(&data_len), file_data, current_pos)do return _report_error("unable to read image resource data length");

		if data_len > 0 {
			data := make([]byte, data_len);
			if !_read_from_buffer(data, file_data, current_pos) do return _report_error("unable to read image resource data");
			delete(data);
			if data_len % 2 != 0 do current_pos^ += 1;
		}

		if current_pos^ - image_rs_start_pos >= u32(image_rs_len) do break;
	}

	return true;
}

// ----------------------------------------------------------------------------

psd_create_layer_image :: proc(layer: ^Psd_Layer_Info, dWidth, dHeight: int, file_data: []byte) -> []byte{
	find_channel :: proc(layer: Psd_Layer_Info, id: i32) -> int {
		result := -1;
		for channel, index in layer.channel_info {
			if channel.id == id {
				result = index;
			}
		}

		return result;
	}
	width := _width_of(layer.dimensions);
	height := _height_of(layer.dimensions);
	for cidx in 0 ..< layer.channel_count {
		cWidth:int = width;
		cHeight: int = height;
		channel := layer.channel_info[cidx];
		current_pos := u32(channel.offset);
		if channel.id > -3 {
			if channel.id == -2 {
				cWidth = _width_of(layer.transparentMask);
				cHeight = _height_of(layer.transparentMask);
			}
			if image, image_ok := _read_image_data(cWidth, cHeight, file_data, &current_pos); !image_ok {
				return {};
			}
			else {
				append(&layer.channel_images, image);
			}
		} 
	}
	if len(layer.channel_images) > 0 {
		rIndex := find_channel(layer^, 0);
		gIndex := find_channel(layer^, 1);
		bIndex := find_channel(layer^, 2);
		aIndex := find_channel(layer^, -1);
		maskIndex := -1;

		if layer.hasMask {
			maskIndex = find_channel(layer^, -2);
		}


		if height + width != 0 {
			layer.composited_image = make([]byte, dWidth * dHeight * 4);
			for h in 0..<dHeight{

				for w in 0..<dWidth {
					layerX := w - int(layer.dimensions.left);
					layerY := h - int(layer.dimensions.top);
					channelValue := (layerY * width) + layerX;
					finalPixel := (h * dWidth) + w;

					idx := finalPixel * 4;
					
					if layerX < 0 || layerX >= width || layerY < 0 || layerY >= height {
						layer.composited_image[idx + 0] = 0;
						layer.composited_image[idx + 1] = 0;
						layer.composited_image[idx + 2] = 0;
						layer.composited_image[idx + 3] = 0;
						continue;
					}
					r := layer.channel_images[rIndex];
					g := layer.channel_images[gIndex];
					b := layer.channel_images[bIndex];
					a := layer.channel_images[aIndex];

					layer.composited_image[idx + 0] = r.image_data[channelValue];
					layer.composited_image[idx + 1] = g.image_data[channelValue];
					layer.composited_image[idx + 2] = b.image_data[channelValue];
					layer.composited_image[idx + 3] = a.image_data[channelValue];
					if maskIndex != -1   {
						docX := int(layer.dimensions.left) + layerX;
						docY := int(layer.dimensions.top) + layerY;
						maskX := docX - int(layer.transparentMask.left);
						maskY := docY - int(layer.transparentMask.top);
						maskWidth := _width_of(layer.transparentMask);
						maskHeight := _height_of(layer.transparentMask);

						value : u8;

						mask := layer.channel_images[maskIndex];
						if maskX < 0 || maskX >= maskWidth || maskY < 0 || maskY >= maskHeight {
							value = 0;
						} else {
							value = mask.image_data[maskY * maskWidth + maskX];
						}

						percent := f32(value)/f32(255);
						alpha := layer.composited_image[idx + 3];
						alpha = u8(f32(alpha) * percent);
						layer.composited_image[idx + 3] = alpha;
					}
				}
			}
		}
	} else {
		fmt.println("no images why?", layer.name);
	}
	return layer.composited_image;
}

_psd_read_layer_and_mask_data :: proc(file_info : ^Psd_File_Info, file_data: []byte, current_pos: ^u32) -> bool {
	layer_mask_len : u32be;
	if !_read_from_buffer(mem.ptr_to_bytes(&layer_mask_len), file_data, current_pos) do return _report_error("unable to read layer mask length");
	_psd_log("layer_mask_len = ", layer_mask_len);

	layer_mask_start_pos := current_pos^;

	layer_len : i32be;
	if !_read_from_buffer(mem.ptr_to_bytes(&layer_len), file_data, current_pos) do return _report_error("unable to read layer section length");
	_psd_log("layer_len = ", layer_len);

	layer_count : i16be;
	if !_read_from_buffer(mem.ptr_to_bytes(&layer_count), file_data, current_pos) do return _report_error("unable to read layer count");
	_psd_log("layer_count = ", layer_count);

	file_info.first_layer_transparent = layer_count < 0; // first_alpha_channel_contains_transparency_data

	layer_count = layer_count < 0 ? -layer_count : layer_count;
	for l in 0 ..< layer_count {
		if current_pos^ > layer_mask_start_pos + u32(layer_mask_len) {
			_psd_log("exceeded layer mask position, exiting");
			break;
		}
		_psd_logf("layer {0} of {1}\n", l+1, layer_count);
		layer_info : Psd_Layer_Info;

		if !_read_from_buffer(mem.ptr_to_bytes(&layer_info.dimensions), file_data, current_pos) do return _report_error("unable to read layer dimensions");
		_psd_log("layer dimensions: ", layer_info.dimensions);


		if !_read_from_buffer(mem.ptr_to_bytes(&layer_info.channel_count), file_data, current_pos) do return _report_error("unable to read layer channel count");
		_psd_log("channel_count = ", layer_info.channel_count);


		channel_info_start := current_pos^;

		layer_info.channel_info = make([]Psd_Channel_Info, layer_info.channel_count);
		for c in 0..<layer_info.channel_count {
			info : Psd_Channel_Info;
			id : i16be;
			size : u32be;
			_read_from_buffer(mem.ptr_to_bytes(&id), file_data, current_pos);
			_read_from_buffer(mem.ptr_to_bytes(&size), file_data, current_pos);	
			info.data = u32(size);
			info.id = i32(id);
			layer_info.channel_info[c] = info;
		}


		current_pos^ = channel_info_start + u32(layer_info.channel_count * 6);

		blend_mode_signature : [4]byte;
		if !_read_from_buffer(blend_mode_signature[:], file_data, current_pos) do return _report_error("unable to read blend mode signature");

		blend_mode_signature_str := strings.string_from_ptr(&blend_mode_signature[0], len(blend_mode_signature));
		if blend_mode_signature_str != "8BIM" do return _report_error("layer blend mode signature mismatch. ", blend_mode_signature_str);

		if !_read_from_buffer(mem.ptr_to_bytes(&layer_info.layer_record), file_data, current_pos) do return _report_error("unable to read layer record");
		_psd_log("layer_record = ", layer_info.layer_record);

		extra_data_start := current_pos^;

		layer_mask_header_size : u32be;
		if !_read_from_buffer(mem.ptr_to_bytes(&layer_mask_header_size), file_data, current_pos) do return _report_error("unable to read layer mask header size");
		_psd_log("layer_mask_header_size = ", layer_mask_header_size);

		if layer_mask_header_size != 0 {
			Layer_Mask_Header :: struct #packed {
				top, left, bottom, right : i32be,
				default_color : byte,
				flags : byte,
			};

			Layer_Mask_Header_Flag :: enum u8 {
				PositionRelativeToLayer       = (1<<0),
				LayerMaskDisabled             = (1<<1),
				InvertLayerMaskWhenBlending   = (1<<2),
				MaskFromRenderingData         = (1<<3),
				UserAndOrVectorMaskHaveParams = (1<<4),
			};



			layer_mask_header : Layer_Mask_Header;
			if !_read_from_buffer(mem.ptr_to_bytes(&layer_mask_header), file_data, current_pos) do return _report_error("unable to read layer mask header");
			_psd_log(layer_mask_header);
			if int( Layer_Mask_Header_Flag(layer_mask_header.flags) & Layer_Mask_Header_Flag.UserAndOrVectorMaskHaveParams) != 0{
				mask_params : byte;
				if !_read_from_buffer(mem.ptr_to_bytes(&mask_params), file_data, current_pos) do return _report_error("unable to read layer mask parameters");
				_psd_log("mask_params = ", mask_params);

				if mask_params & (1<<0) != 0 {
					usr_mask_density : byte;
					if !_read_from_buffer(mem.ptr_to_bytes(&usr_mask_density), file_data, current_pos) do return _report_error("unable to read layer user mask density");
					_psd_log("usr_mask_density = ", usr_mask_density);
				}
				else if mask_params & (1<<1) != 0 {
					usr_mask_feather : f64be;
					if !_read_from_buffer(mem.ptr_to_bytes(&usr_mask_feather), file_data, current_pos) do return _report_error("unable to read layer user mask feather");
					_psd_log("usr_mask_feather = ", usr_mask_feather);
				}
				if mask_params & (1<<2) != 0 {
					vec_mask_density : byte;
					if !_read_from_buffer(mem.ptr_to_bytes(&vec_mask_density), file_data, current_pos) do return _report_error("unable to read layer vector mask density");
					_psd_log("vec_mask_density = ", vec_mask_density);
				}
				else if mask_params & (1<<3) != 0 {
					vec_mask_feather : f64be;
					if !_read_from_buffer(mem.ptr_to_bytes(&vec_mask_feather), file_data, current_pos) do return _report_error("unable to read layer vector mask feather");
					_psd_log("vec_mask_feather = ", vec_mask_feather);
				}
			} else if layer_mask_header.flags & u8(Layer_Mask_Header_Flag.LayerMaskDisabled) == 0 {
				layer_info.hasMask = true;
				layer_info.transparentMask = {layer_mask_header.top, layer_mask_header.left, layer_mask_header.bottom, layer_mask_header.right};
			}

			if layer_mask_header_size == 20 {
				current_pos^ += 2; // skip padding
			}
			else {
				Layer_Mask_Details :: struct #packed {
					real_flags : byte,
					real_user_mask_bg : byte,
					top, left, bottom, right : u32be,
				};
				layer_mask_details : Layer_Mask_Details;
				if !_read_from_buffer(mem.ptr_to_bytes(&layer_mask_details), file_data, current_pos) do return _report_error("unable to read layer mask details");
				_psd_log(layer_mask_details);
			}
		}


		Layer_Blending_Range :: struct #packed {
			length : u32be,
			composite_gray_blend_source : i32be,
			composite_gray_blend_dest_range : i32be,
		};

		layer_blending_range : Layer_Blending_Range;
		layer_blending_section_start := current_pos^;
		if !_read_from_buffer(mem.ptr_to_bytes(&layer_blending_range), file_data, current_pos) do return _report_error("unable to read layer blending range");
		/*
		_psd_log(layer_blending_range);
		//Chanel count includes the composite gray blend and we already read those
		for c in 0..< layer_info.channel_count - 1{
			channel_source_range, channel_dest_range : u32be;
			if !_read_from_buffer(mem.ptr_to_bytes(&channel_source_range), file_data, current_pos) do return _report_error("unable to read channel source range");
			if !_read_from_buffer(mem.ptr_to_bytes(&channel_dest_range), file_data, current_pos) do return _report_error("unable to read channel destination range");

			_psd_log("channel ", c, " source = ", channel_source_range, " dest = ", channel_dest_range);
		}
		*/
		current_pos^ = (layer_blending_section_start + 4) + u32(layer_blending_range.length);

		layer_name_len : byte;
		if !_read_from_buffer(mem.ptr_to_bytes(&layer_name_len), file_data, current_pos) do return _report_error("unable to read layer name length");
		if layer_name_len != 0 {
			layer_name_bytes : [256]byte;
			if !_read_from_buffer(layer_name_bytes[:layer_name_len], file_data, current_pos) do return _report_error("unable to read layer name");
			_psd_log("layer_name = ", strings.string_from_ptr(&layer_name_bytes[0], int(layer_name_len)), " len:", layer_name_len);

			layer_info.name = strings.clone(strings.string_from_ptr(&layer_name_bytes[0], int(layer_name_len)));
		}
		layer_name_padded := u32(layer_name_len) + 1;
		if layer_name_padded % 4 != 0 {
			pad := 4 - (layer_name_padded % 4);
			layer_name_padded += pad;
			current_pos^ += pad;
		}
		start_additional_data := current_pos^;
		additionalLayerInfoSize := u32(layer_info.layer_record.extra_data_field_len) - u32(layer_mask_header_size) - u32(layer_blending_range.length) - layer_name_padded - 8;
		toRead := additionalLayerInfoSize;
		// the specs say that the layer name is supposed to be padded to 4 bytes, but adjusting the current position based on the length of
		// the layer name string didn't seem to work.  so just search the next 16 bytes for the expected signature

		// check for extra information added with Photoshop 4 and later
		for toRead > 0{
			lastPos := current_pos^;
			signature : [4]byte;
			if !_read_from_buffer(signature[:], file_data, current_pos) do return _report_error("unable to read additional layer information signature");
			signature_string := strings.string_from_ptr(&signature[0], len(signature));
			if signature_string != "8BIM" && signature_string != "8B64" {
				_psd_log("SIG: ", signature_string);
				current_pos^ -= 4;
				break;
			}

			key_code: [4]byte;
			if !_read_from_buffer(key_code[:], file_data, current_pos) do return _report_error("unable to read additional layer information keycode");
			keycode_str := strings.string_from_ptr(&key_code[0], len(key_code));
			_psd_log("keycode_str = ", keycode_str);

			length : u32be;
			if !_read_from_buffer(mem.ptr_to_bytes(&length), file_data, current_pos) do return _report_error("unable to read additional layer information length");
			_psd_log("info length = ", length);


			start := current_pos^;

			if keycode_str == "lsct" {
				type : u32be;
				if !_read_from_buffer(mem.ptr_to_bytes(&type), file_data, current_pos) do return _report_error("unable to read lsct type");
				if type == 1 || type == 2 {
					layer_info.group = true;
				}
				current_pos^ += u32(length - 4);
			}
			//utf-16 name
			else if keycode_str == "luni" {
				total_characters : u32be;

				if !_read_from_buffer(mem.ptr_to_bytes(&total_characters), file_data, current_pos) do return _report_error("couldn't read layer unicode name length");

				utf16Name := make([]u16be, total_characters);
				defer delete(utf16Name);
				for char in 0..<total_characters {
					_read_from_buffer(mem.ptr_to_bytes(&utf16Name[char]), file_data, current_pos);
				}
				skip := u32(length - 4 - total_characters * 2);
				current_pos^ += skip;
			} else if keycode_str == "lyid" {
				//skip length
				id : i32be;
				if !_read_from_buffer(mem.ptr_to_bytes(&id), file_data, current_pos) {
					return _report_error("Couldn't read layer id");
				}
				layer_info.id = id;
				_psd_log(layer_info.id, id, layer_info.name);
				current_pos^ += u32(length - 4);
			} else {
				current_pos^ += u32(length);
			}
			//Just jump to where we should be. Maybe we read something bad?
			current_pos^ = lastPos + 12 + u32(length);
			toRead -= 12 + u32(length);
		}
		current_pos^ = extra_data_start + u32(layer_info.layer_record.extra_data_field_len);
		append(&file_info.layers, layer_info);
	}

	for layer, lidx in &file_info.layers {
		for cidx in 0 ..< layer.channel_count {
			channel_start_pos := current_pos^;
			_psd_log("LAYER ", lidx+1, layer.name, " CHANNEL ", cidx+1);
			channel := &layer.channel_info[cidx];
			channel.offset = u64(channel_start_pos);
			current_pos^ = channel_start_pos + channel.data;
		}
	}

	current_pos^ = layer_mask_start_pos + u32(layer_mask_len);

	// do group paths

	{
		buffer : [1024]byte;
		builder := strings.builder_from_slice(buffer[:]);
		current_path := "";

		for i := len(file_info.layers) - 1; i >= 0; i -= 1 {
			layer := &file_info.layers[i];

			if layer.name == "</Layer group>" {
				pos_last := strings.last_index(current_path, "/");
				existing := strings.clone(current_path[:max(0, pos_last)], context.temp_allocator);
				strings.reset_builder(&builder);
				fmt.sbprint(&builder, existing);
				current_path = strings.to_string(builder);
				layer.group = true;
			}
			else if layer.group {
				existing := strings.clone(current_path[:], context.temp_allocator);
				strings.reset_builder(&builder);
				if existing != "" {
					fmt.sbprint(buf = &builder, args = {existing, "/"});
				}
				fmt.sbprint(&builder, layer.name);
				current_path = strings.to_string(builder);
				_psd_log("new path:", current_path);
			}
			else {
				layer.group_path = strings.clone(current_path);
				_psd_log("layer", layer.name, " group: ", layer.group_path);
			}
		}
	}

	return true;
}

// ----------------------------------------------------------------------------

_psd_read_image_data :: proc(file_info : ^Psd_File_Info, file_data: []byte, current_pos: ^u32) -> bool {

	// stored RRRR...GGGG...BBBB...AAAA....

	w := int(file_info.file_header.width_in_pixels);
	h := int(file_info.file_header.height_in_pixels);

	_psd_log("reading composited image.  dims:", w, "x", h);

	if image, image_ok := _read_image_data(w, h * 4, file_data, current_pos); !image_ok {
		return false;
	}
	else {
		pixels := make([]byte, w * h * 4);

		for y in 0 ..< h {
			for x in 0 ..< w {
				pidx := (y * w) + x;

				pixels[(pidx * 4) + 0] = image.image_data[(w * h) * 0 + pidx];
				pixels[(pidx * 4) + 1] = image.image_data[(w * h) * 1 + pidx];
				pixels[(pidx * 4) + 2] = image.image_data[(w * h) * 2 + pidx];
				pixels[(pidx * 4) + 3] = image.image_data[(w * h) * 3 + pidx];
			}
		}
		file_info.composited_image = pixels;

		delete(image.image_data);
		return true;
	}
}

// ----------------------------------------------------------------------------

_read_image_data ::proc(width, height: int, file_data: []byte, current_pos: ^u32) -> (Psd_Channel_Image, bool) {
	compression : u16be;
	if !_read_from_buffer(mem.ptr_to_bytes(&compression), file_data, current_pos) do return {}, _report_error("unable to read channel compression type");
	//_psd_log("channel ", cidx, " compression = ", compression);

	_psd_log("layer dims: ", width, " x ", height);
	if width + height == 0 do return {}, true;

	image : Psd_Channel_Image;
	image.image_data = make([]byte, width * height);

	if compression == 0 { // raw image
	if !_read_from_buffer(image.image_data, file_data, current_pos) do return {}, _report_error("unable to read uncompressed channel image data");
}
else if compression == 1 { // RLE compressed
if !_rle_decode(width, height, &image, file_data, current_pos) do return {}, false;
	}
	else if compression == 2 { // ZIP without prediction
	return {}, _report_error("unsupported compression encountered [2]");
}
else if compression == 3 { // ZIP with prediction
return {}, _report_error("unsupported compression encountered [3]");
	}
	else {
		return {}, _report_error("unexpected compression encountered:", compression);
	}

	return image, true;
}

// ----------------------------------------------------------------------------

_rle_decode :: proc (width, height : int, image: ^Psd_Channel_Image, file_data:[]byte, current_pos : ^u32) -> bool {
	rle_scanlines := make([]i16be, height);
	defer delete(rle_scanlines);
	if !_read_from_buffer(mem.ptr_to_bytes(&rle_scanlines[0], height), file_data, current_pos) do return _report_error("unable to read rle scanlines");

	max_length : i16be = 0;
	totalSize := 0;
	for i in 0..<height {
		totalSize += int(rle_scanlines[i]);
		max_length = max(max_length, rle_scanlines[i]);
	}

	_psd_log("max length = ", max_length);

	image_idx := 0;
	rows_by_width := 0;
	rows_by_stop := 0;
	for h in 0..<height {
		// decode each scanline
		scanline_len := rle_scanlines[h];
		stop_pos := current_pos^ + u32(scanline_len);

		if scanline_len % 2 != 0 {
			//stop_pos += 1;
		}

		sections := 0;
		pos := 0;
		neg := 0;
		pixels_this_row := 0;
		for {
			if image_idx >= len(image.image_data) {
				fmt.println("overran");
				return _report_error("overran data");
			}
			header : i8;
			if !_read_from_buffer(mem.ptr_to_bytes(&header), file_data, current_pos) do return _report_error("unable to read rle header");
			sections += 1;
			if header >= 0 { // 1 + header bytes of data
			iheader := int(header) + 1;
			if !_read_from_buffer(mem.ptr_to_bytes(&image.image_data[image_idx], iheader), file_data, current_pos) do return _report_error("unable to read rle data");
			image_idx += iheader;
			pixels_this_row += iheader;
			pos += 1;
		}
		else if header != -128 { // one byte of data repeated (1 - header) times
		data_byte : byte;
		if !_read_from_buffer(mem.ptr_to_bytes(&data_byte), file_data, current_pos) do return _report_error("unable to read rle data byte");
		run := int(-header) + 1;
		for d := 0; d < run; d += 1 {
			if image_idx < len(image.image_data) {
				image.image_data[image_idx] = data_byte;
			}
			image_idx += 1;
			pixels_this_row += 1;
		}
		neg += 1;
	}
	// else no operation, just skip and grab the next header

	if current_pos^ >= stop_pos {
		if current_pos^ > stop_pos {
			_psd_log("went over by ", current_pos^ - stop_pos);
		}
		rows_by_stop += 1;
		if pixels_this_row > width do _psd_log("row over by ", pixels_this_row - width, " pixels");

		if pixels_this_row < width {
			_psd_log("row ", h, " is short ", width-pixels_this_row, " pixels.  sections: ", sections, " pos:", pos, " neg:", neg);
			image_idx += width - pixels_this_row;
		}

		break;
	}
}
	}

	_psd_log("rows_by_width = ", rows_by_width, "  rows_by_stop = ", rows_by_stop);

	if image_idx != width * height {
		_psd_log("image mismatch.  index:", image_idx, " calc:", width * height);
	}

	return true;
}


_width_of :: proc (dims : Psd_Dimensions) -> int {
	return int(dims.right - dims.left);
}

_height_of :: proc(dims : Psd_Dimensions) -> int {
	return int(dims.bottom - dims.top);
}


_read_from_buffer :: proc (dest : []byte, source : []byte, current_pos : ^u32) -> bool {
	if u32(len(source)) < current_pos^ + u32(len(dest)) {
		_psd_log_error("trying to read", u32(len(dest)), "bytes when only", u32(len(source)) - current_pos^, "bytes remain (out of", len(source), ")");
		return false;
	}

	copy(dest, source[current_pos^:current_pos^ + u32(len(dest))]);
	current_pos^ += u32(len(dest));

	return true;
}


_report_error :: proc (args : ..any) -> bool {
	_psd_log_error(..args);
	return false;
}

_psd_log :: proc(args : ..any, location := #caller_location) {
	//fmt.println(..args);
	log.debug(args=args, location=location);
}

_psd_logf :: proc(format:string, args : ..any) {
	//	log.debugf(format, ..args);
}

_psd_log_error :: proc(args : ..any) {
	//fmt.println(..args);
	log.error(..args);
}
