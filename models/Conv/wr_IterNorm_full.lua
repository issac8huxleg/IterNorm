--  Wide Residual Network
--  This is an implementation of the wide residual networks described in:
--  "Wide Residual Networks", http://arxiv.org/abs/1605.07146
--  authored by Sergey Zagoruyko and Nikos Komodakis

--  ************************************************************************
--  This code incorporates material from:

--  fb.resnet.torch (https://github.com/facebook/fb.resnet.torch)
--  Copyright (c) 2016, Facebook, Inc.
--  All rights reserved.
--
--  This source code is licensed under the BSD-style license found in the
--  LICENSE file in the root directory of this source tree. An additional grant
--  of patent rights can be found in the PATENTS file in the same directory.
--
--  ************************************************************************

local nn = require 'nn'
 require 'cunn'
 require 'cudnn'
 require '../../module/spatial/Spatial_DBN_PowerIter'
local utils = paths.dofile'utils.lua'


assert(opt and opt.depth)
assert(opt and opt.num_classes)
assert(opt and opt.widen_factor)

local Convolution = nn.SpatialConvolution
local Avg = nn.SpatialAveragePooling
local ReLU = nn.ReLU
local Max = nn.SpatialMaxPooling
local SBatchNorm = nn.SpatialBatchNormalization

local function Dropout()
   return nn.Dropout(opt and opt.dropout or 0,nil,true)
end

local function createModel(opt)
   local depth = opt.depth

   local blocks = {}
   
   local function wide_basic(nInputPlane, nOutputPlane, stride)
      local conv_params = {
         {3,3,stride,stride,1,1},
         {3,3,1,1,1,1},
      }
      local nBottleneckPlane = nOutputPlane

      local block = nn.Sequential()
      local convs = nn.Sequential()     

      for i,v in ipairs(conv_params) do
         if i == 1 then
            local module = nInputPlane == nOutputPlane and convs or block
            --module:add(SBatchNorm(nInputPlane)):add(ReLU(true))
            module:add(nn.Spatial_DBN_PowerIter(nInputPlane,opt.m_perGroup, opt.nIter,_,true)):add(ReLU(true))
            convs:add(Convolution(nInputPlane,nBottleneckPlane,table.unpack(v)))
         else
            convs:add(nn.Spatial_DBN_PowerIter(nBottleneckPlane,opt.m_perGroup, opt.nIter,_,true)):add(ReLU(true))
            --convs:add(SBatchNorm(nBottleneckPlane)):add(ReLU(true))
            if opt.dropout > 0 then
               convs:add(Dropout())
            end
            convs:add(Convolution(nBottleneckPlane,nBottleneckPlane,table.unpack(v)))
         end
      end
     
      local shortcut = nInputPlane == nOutputPlane and
         nn.Identity() or
         Convolution(nInputPlane,nOutputPlane,1,1,stride,stride,0,0)
     
      return block
         :add(nn.ConcatTable()
            :add(convs)
            :add(shortcut))
         :add(nn.CAddTable(true))
   end

   -- Stacking Residual Units on the same stage
   local function layer(block, nInputPlane, nOutputPlane, count, stride)
      local s = nn.Sequential()

      s:add(block(nInputPlane, nOutputPlane, stride))
      for i=2,count do
         s:add(block(nOutputPlane, nOutputPlane, 1))
      end
      return s
   end

   local model = nn.Sequential()
   do
      assert((depth - 4) % 6 == 0, 'depth should be 6n+4')
      local n = (depth - 4) / 6

      local k = opt.widen_factor
      local nStages = torch.Tensor{16, 16*k, 32*k, 64*k}

      model:add(Convolution(3,nStages[1],3,3,1,1,1,1)) -- one conv at the beginning (spatial size: 32x32)
      model:add(nn.Spatial_DBN_PowerIter(nStages[1],opt.m_perGroup, opt.nIter,_,true))
      model:add(layer(wide_basic, nStages[1], nStages[2], n, 1)) -- Stage 1 (spatial size: 32x32)
      model:add(layer(wide_basic, nStages[2], nStages[3], n, 2)) -- Stage 2 (spatial size: 16x16)
      model:add(layer(wide_basic, nStages[3], nStages[4], n, 2)) -- Stage 3 (spatial size: 8x8)
      model:add(nn.Spatial_DBN_PowerIter(nStages[4],opt.m_perGroup, opt.nIter,_,true))
      model:add(ReLU(true))
      model:add(Avg(8, 8, 1, 1))
      model:add(nn.View(nStages[4]):setNumInputDims(3))
      model:add(nn.Linear(nStages[4], opt.num_classes))
   end

   utils.DisableBias(model)
--   utils.MSRinit(model)
   utils.FCinit(model)
   
   -- model:get(1).gradInput = nil

   return model
end

return createModel(opt)