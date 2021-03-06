% parts reattention test
%% first calculate the weight matrix
% load the data
featurePath=['/x/yang/exp_data/fv_layer/exp_yang_fv/',...
             'poolout_CUB_VGG_16_conv5_relu_448.mat'];
load(featurePath);
% load the imdb
partFileLoc='/x/yang/exp_data/fv_layer/exp01/cub-seed-01/imdb/parts.mat';
load(partFileLoc);
%% train the classifier
addpath ./no_publish/layers/pooling/
addpath ./no_publish/layers/normalize/

[trainFV_ave, valFV_ave]=pool_ave(trainFV, valFV); 
[trainFV_root, valFV_root]=normalize_root(trainFV_ave, valFV_ave);
[trainFV_l2, valFV_l2]=normalize_l2(trainFV_root, valFV_root);
[w, b, acc, map, cls]=...
   train_test_vlfeat('LR', trainFV_l2, trainY, valFV_l2, valY);
%% for each image, crop out the attended part, from top5 scores
% tools: id2raw_index
index_val=find(imdb.images.set == 3);
index_train=find(imdb.images.set == 1);
get_raw_index_train=@(x)index_train(x); 
get_raw_index_val=@(x)index_val(x); 

% tool: raw_index2image
getbatch=getBatchWrapper(struct('numThreads', 4,...
      'imageSize', [448 448 3], 'averageImage', [0 0 0]));
readImage=@(gid) uint8(getbatch(imdb, gid));

% tool: signed sqrt
sign_sqrt=@(x) sqrt(abs(x)).*sign(x);

% start cropping, from training
doVis=1;
doAbandonLargeCrop=0;
borderAround=3;

Y=valY;
FV=valFV;
cls=bsxfun(@plus, w'*valFV_l2, b'); % has size 200*5794
get_raw_index=@(x) get_raw_index_val(x);
readCur=@(x)readImage(get_raw_index_val(x));

[nh,nw,nc,nn] = size(FV);
[B, I]=sort(cls, 1, 'descend');  % now we care about I(1:5, :)
iim=1;
feature=sign_sqrt(squeeze(FV(:,:,:,iim)));
im=readCur(iim);
if doVis
    subplot(2,4,1);
    imshow(im);
end
map=zeros(nh, nw);
topn=5;
for topi=1:topn
    class=I(topi, iim);
    
    % get out the weight
    weight= reshape(w(:, class), 1, 1, []);
    activations=dot(feature, repmat(weight, nh, nw, 1), 3)+b(class);
                
    % some visualization code
    if doVis
        subplot(2,4,topi+1);
        imagesc(activations);
        colorbar
        
        title(['Actual=', num2str(Y(iim)), ...
               ', predicted=', num2str(I(1, iim)), ...
               ', weights=', num2str(class)]);
    end
    % get the maximum response location and mark it in the map
    [~, maxInd] = max(activations(:));
    if map(maxInd)==0
        % only save when the previous maximum don't occupy this
        map(maxInd)=topi;
    end
    
end

if doVis
    subplot(2,4,7);
    imagesc(map);
    colorbar
    title('maximum activation location')
end

% then calculate a bounding box around point of interests
% first make sure that it could be covered by a half*half box
tlm=0; tln=0; brm=0; brn=0;
for i=1:topn
    loc = find(map(:) ==i);
    assert(numel(loc) <= 1);
    if numel(loc) ==0
        continue;
        % the maximum is the same as something else
    end
    locm = mod(loc-1, nh)+1;
    locn = floor((loc-1) / nh) + 1;
    if i==1
        tlm = locm;
        tln = locn;
        brm = locm;
        brn = locn;
    else
        ntlm=min(tlm, locm);
        ntln=min(tln, locn);
        nbrm=max(brm, locm);
        nbrn=max(brn, locn);
        if ((nbrn-ntln+1 > nw/2) || (nbrm - ntlm+1 >= nh/2)) && ...
                doAbandonLargeCrop
            fprintf('Image %d, top %d-th, abandoned, due to out of box', ...
                    iim, i);
        else
            tlm=ntlm;
            tln=ntln;
            brm=nbrm;
            brn=nbrn;
        end
    end
end
if doVis
    [tlm tln]
    [brm brn]
end

% then inflate the box to half the size
mamount=(nh/2-(brm-tlm))/2;
if mamount>0
    % if already larger, then don't inflate
    tlm=tlm-mamount;
    brm=brm+mamount;
end
% add some border around 
tlm=tlm-borderAround;
brm=brm+borderAround;

namount=(nw/2-(brn-tln))/2;
if namount>0
    tln=tln-namount;
    brn=brn+namount;
end
% add some border around
tln=tln-borderAround;
brn=brn+borderAround;

if doVis
    [tlm tln]
    [brm brn]
end
% read the original image 
imname=[imdb.imageDir '/' imdb.images.name{get_raw_index(iim)}];
imo0=imread(imname);
factor=max((448)/size(imo0,1), (448)/size(imo0,2));
imo=imresize(imo0, factor);
start=size(imo);
start=ceil((start(1:2)+1-448)/2);

% map to original image coordinate
tlm=tlm/nh*448+start(1); brm=brm/nh*448+start(1);
tln=tln/nw*448+start(2); brn=brn/nw*448+start(2);
if doVis
    [tlm tln]
    [brm brn]
end
% if out of image, then move the box
sz=size(imo);
if tlm<=0
    brm=brm-tlm+1;
    tlm=1;
end
if brm>sz(1)
    tlm=tlm-(brm-sz(1));
    brm=brm-(brm-sz(1));
end
if tln<=0
    brn=brn-(tln-1);
    tln=tln-(tln-1);
end
if brn>sz(2)
    tln=tln-(brn-sz(2));
    brn=brn-(brn-sz(2));
end
% change the output from resized to the original
%out=imo(tlm:brm, tln:brn, :);
trans=@(x, dim) ceil(x/size(imo, dim)*size(imo0, dim));
out=imo0(trans(tlm,1):trans(brm,1), trans(tln, 2):trans(brn, 2), :);
if doVis
    subplot(2,4,8);
    imshow(out);
end

