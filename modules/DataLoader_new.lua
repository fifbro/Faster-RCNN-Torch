require 'hdf5'
local utils = require 'utils.utils'
local box_utils = require 'utils.box_utils'
local image = require 'image'
local ffi = require 'ffi'
local cv = require 'cv'
require 'cv.imgproc'
require 'cv.imgcodecs'
require 'cv.highgui'

local DataLoader = torch.class('DataLoader')

function DataLoader:__init(opt)
  self.h5_file = utils.getopt(opt, 'data_h5') -- required h5file with images and other (made with prepro script)
  self.json_file = utils.getopt(opt, 'data_json') -- required json file with vocab etc. (made with prepro script)
  self.debug_max_train_images = utils.getopt(opt, 'debug_max_train_images', -1)
  self.proposal_regions_h5 = utils.getopt(opt, 'proposal_regions_h5', '')
  self.image_size = utils.getopt(opt, 'image_size', '720')
  
  -- load the json file which contains additional information about the dataset
  print('DataLoader loading json file: ', self.json_file)
  self.info = utils.read_json(self.json_file)
  self.num_classes = utils.count_keys(self.info.idx_to_cls)

  -- Convert keys in idx_to_token from string to integer
  local idx_to_cls = {}
  for k, v in pairs(self.info.idx_to_cls) do
    idx_to_cls[tonumber(k)] = v
  end
  self.info.idx_to_cls = idx_to_cls

  -- open the hdf5 file
  print('DataLoader loading h5 file: ', self.h5_file)
  self.h5_file = hdf5.open(self.h5_file, 'r')
  local keys = {}
  table.insert(keys, 'box_to_img')
  table.insert(keys, 'boxes')
  table.insert(keys, 'img_to_first_box')
  table.insert(keys, 'img_to_last_box')
  table.insert(keys, 'labels')
  table.insert(keys, 'iscrowd')
  table.insert(keys, 'difficult')
  table.insert(keys, 'split')
  for k,v in pairs(keys) do
    print('reading ' .. v)
    local ok, tmp = pcall(function()
      return self.h5_file:read('/' .. v):all()
    end)
    self[v] = tmp
  end

  -- open region proposals file for reading. This is useful if we, e.g.
  -- want to use the ground truth boxes, or if we want to use external region proposals
  if string.len(self.proposal_regions_h5) > 0 then
    print('DataLoader loading objectness boxes from h5 file: ', self.proposal_regions_h5)
    self.obj_boxes_file = hdf5.open(self.proposal_regions_h5, 'r')
    self.obj_img_to_first_box = self.obj_boxes_file:read('/img_to_first_box'):all()
    self.obj_img_to_last_box = self.obj_boxes_file:read('/img_to_last_box'):all()
  end
  
  -- extract image size from dataset
  self.num_images = self.img_to_first_box:size(1)
  self.num_channels = 3

  -- extract some attributes from the data
  self.num_regions = self.boxes:size(1)
--  self.vgg_mean = torch.FloatTensor{103.939, 116.779, 123.68} -- BGR order
  self.vgg_mean = torch.FloatTensor{102.98, 115.9465, 122.7717} -- BGR order
--  self.vgg_mean = torch.FloatTensor{122.7717, 115.9465, 102.98} -- BGR order
--  self.vgg_mean = self.vgg_mean:view(1,3,1,1)
  self.vgg_mean = self.vgg_mean:view(1,1,3)

  -- set up index ranges for the different splits
  self.train_ix = {}
  self.val_ix = {}
  self.test_ix = {}
  for i=1,self.num_images do
    if self.split[i] == 0 then table.insert(self.train_ix, i) end
    if self.split[i] == 1 then table.insert(self.val_ix, i) end
    if self.split[i] == 2 then table.insert(self.test_ix, i) end
  end

  self.iterators = {[0]=1,[1]=1,[2]=1} -- iterators (indices to split lists) for train/val/test
  print(string.format('assigned %d/%d/%d images to train/val/test.', #self.train_ix, #self.val_ix, #self.test_ix))

  print('initialized DataLoader:')
  print(string.format('#images: %d, #regions: %d', 
                      self.num_images, self.num_regions))
end

function DataLoader:getNumClasses()
  return self.num_classes
end

function DataLoader:getClasses()
  return self.info.idx_to_cls
end

function DataLoader:_loadImage(path)
   local ok, input = pcall(function()
      return image.load(path, 3,'float')
   end)
   -- Sometimes image.load fails because the file extension does not match the
   -- image format. In that case, use image.decompress on a ByteTensor.
   if not ok then
      local f = io.open(path, 'r')
      assert(f, 'Error reading: ' .. tostring(path))
      local data = f:read('*a')
      f:close()

      local b = torch.ByteTensor(string.len(data))
      ffi.copy(b:data(), data, b:size(1))

      input = image.decompress(b, 3, 'float')
   end

   return input
end

--[[
take a LongTensor of size DxN with elements 1..vocab_size+1 
(where last dimension is END token), and decode it into table of raw text sentences
--]]
function DataLoader:decodeResult(res)
  local N = res:size(1)
  local out = {}
  local itoc = self.info.idx_to_cls
  for i=1,N do
    table.insert(out, itoc[res[i]])
  end
  return out
end

-- split is an integer: 0 = train, 1 = val, 2 = test
function DataLoader:resetIterator(split)
  assert(split == 0 or split == 1 or split == 2, 'split must be integer, either 0 (train), 1 (val) or 2 (test)')
  self.iterators[split] = 1
end

--[[
  split is an integer: 0 = train, 1 = val, 2 = test
  Returns a batch of data in two Tensors:
  - X (1,3,H,W) containing the image
  - B (1,R,4) containing the boxes for each of the R regions in xcycwh format
  - y (1,R,L) containing the (up to L) labels for each of the R regions of this image
  - info table of length R, containing additional information as dictionary (e.g. filename)
  The data is iterated linearly in order. Iterators for any split can be reset manually with resetIterator()
  Returning random examples is also supported by passing in .iterate = false in opt.
--]]
function DataLoader:getBatch(opt)
  local split = utils.getopt(opt, 'split', 0)
  local iterate = utils.getopt(opt, 'iterate', true)

  assert(split == 0 or split == 1 or split == 2, 'split must be integer, either 0 (train), 1 (val) or 2 (test)')
  local split_ix
  if split == 0 then split_ix = self.train_ix end
  if split == 1 then split_ix = self.val_ix end
  if split == 2 then split_ix = self.test_ix end
  assert(#split_ix > 0, 'split is empty?')
  
  -- pick an index of the datapoint to load next
  local ri -- ri is iterator position in local coordinate system of split_ix for this split
  local max_index = #split_ix
  if self.debug_max_train_images > 0 then max_index = self.debug_max_train_images end
  if iterate then
    ri = self.iterators[split] -- get next index from iterator
    local ri_next = ri + 1 -- increment iterator
    if ri_next > max_index then ri_next = 1 end -- wrap back around
    self.iterators[split] = ri_next
  else
    -- pick an index randomly
    ri = torch.random(max_index)
  end
  ix = split_ix[ri]
  assert(ix ~= nil, 'bug: split ' .. split .. ' was accessed out of bounds with ' .. ri)
  
  -- fetch the image
  local filename = self.info.idx_to_filename[tostring(ix)] -- json is loaded with string keys
  assert(filename ~= nil, 'lookup for index ' .. ix .. ' failed in the json info table.')
  --local  img = self:_loadImage(filename)
  local  img = cv.imread{filename}
  print(filename)
  print(img:size())
  img = img:float()
  --print(self.vgg_mean:size())
  img:add(-1, self.vgg_mean:expandAs(img)) -- subtract vgg mean
  local ow,oh = img:size(2), img:size(1)
  local scale = 600.0/torch.min(torch.Tensor{ow,oh})
  if scale*ow > 1000 or scale*oh > 1000 then  scale = 1000.0/torch.max(torch.Tensor{ow,oh}) end
  img = cv.resize{img, fx=scale, fy=scale, interpolation=cv.INTER_LINEAR}
  img = img:permute(3,1,2):contiguous()
  local w,h = img:size(3), img:size(2)
--  img = img:index(1, torch.LongTensor{3, 2, 1})
  img = img:view(1, img:size(1), img:size(2), img:size(3)) -- batch the image
  print(img:size())
--[[  print(img[1][1][1][1])
  print(img[1][2][1][1])
  print(img[1][3][1][1])
  print(img[1][1][2][1])
  print(img[1][2][2][1])
  print(img[1][3][2][1])
  print(img[1][1][1][2])
  print(img[1][2][1][2])
  print(img[1][3][1][2])
  os.exit() --]]
--  for i = 1, img:view(-1):size(1) do
--     print(string.format("%e",img:view(-1)[i]))
--  end
--  os.exit()
  -- fetch the corresponding labels array
  local r0 = self.img_to_first_box[ix]
  local r1 = self.img_to_last_box[ix]
  local label_array = self.labels[{ {r0,r1} }]
  local box_batch = self.boxes[{ {r0,r1} }]
  --box_batch = box_utils.scale_boxes_xywh(box_batch:float(), w/ow)
  box_batch = box_utils.scale_boxes_xywh(box_batch:float(), scale)
  box_batch = box_utils.xywh_to_xcycwh(box_batch):int()

  --[[
  if self.difficult then
    local difficult = self.difficult[{ {r0,r1} }]
    local sel_inds = torch.range(1, r1 - r0 + 1)[difficult:eq(0)]:long()
    if sel_inds:numel() > 0 then
      label_array = label_array:index(1,sel_inds)
      box_batch = box_batch:index(1,sel_inds)
    else
      return self:getBatch(opt) -- if training, return next batch
    end
  end
  ]]--

  -- batch the boxes and labels
  assert(label_array:nDimension() == 1)
  assert(box_batch:nDimension() == 2)
  label_array = label_array:view(1, label_array:size(1), 1)
  box_batch = box_batch:view(1, box_batch:size(1), box_batch:size(2))

  -- finally pull the info from json file
  
  local info_table = { {filename = filename, 
                        split_bounds = {ri, #split_ix},
                        width = w, height = h, ori_width = ow, ori_height = oh, scale = scale} }

  -- read regions if applicable
  local obj_boxes -- contains batch of x,y,w,h,score objectness boxes for this image
  if self.obj_boxes_file then
    local r0 = self.obj_img_to_first_box[ix]
    local r1 = self.obj_img_to_last_box[ix]
    obj_boxes = self.obj_boxes_file:read('/boxes'):partial({r0,r1},{1,5})
    -- scale boxes (encoded as xywh) into coord system of the resized image
    local frac = w/ow -- e.g. if ori image is 800 and we want 512, then we need to scale by 512/800
    local boxes_scaled = box_utils.scale_boxes_xywh(obj_boxes[{ {}, {1,4} }], frac)
    local boxes_trans = box_utils.xywh_to_xcycwh(boxes_scaled)
    obj_boxes[{ {}, {1,4} }] = boxes_trans
    obj_boxes = obj_boxes:view(1, obj_boxes:size(1), obj_boxes:size(2)) -- make batch
  end

  -- TODO: start a prefetching thread to load the next image ?
  return img, box_batch, label_array, info_table, obj_boxes
end
