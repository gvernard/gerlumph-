#include "magnification_map.hpp"


MagnificationMap::MagnificationMap(std::string id,double Rein){
  this->id = id;
  this->convolved = false;
  std::string file;


  // Read map metadata
  file = this->path + this->id + "/mapmeta.dat";
  std::ifstream myfile(file.c_str());
  myfile >> this->avgmu >> this->avgN;
  myfile >> this->Nx;
  myfile >> this->width;
  myfile >> this->k >> this->g >> this->s;
  myfile.close();
  this->Ny = this->Nx;
  this->height = this->width;
  this->pixSizePhys = Rein*this->width/this->Nx; // in units of [10^14 cm]


  // Read map data
  file = this->path + this->id + "/map.bin";

  FILE* ptr_myfile = fopen(file.data(),"rb");
  int* imap = (int*) calloc(this->Nx*this->Ny,sizeof(int));
  fread(imap,sizeof(int),this->Nx*this->Ny,ptr_myfile);
  fclose(ptr_myfile);
  
  //int (4 bytes) and cufftDoubleReal (8 bytes) do not have the same size, so there has to be a type cast
  double factor = fabs(this->avgmu/this->avgN);
  double muth   = fabs( 1.0/(pow(1.0-this->k,2)-pow(this->g,2)) );
  this->data = (double*) calloc(this->Nx*this->Ny,sizeof(double));
  for(long i=0;i<this->Nx*this->Ny;i++){
    this->data[i] = (double) (imap[i]*factor/muth);
  }
  free(imap);
}


MagnificationMap::MagnificationMap(const MagnificationMap& other){
  this->id     = other.id;
  this->k      = other.k;
  this->g      = other.g;
  this->s      = other.s;
  this->Nx     = other.Nx;
  this->Ny     = other.Ny;
  this->width  = other.width;
  this->height = other.height;
  this->avgmu  = other.avgmu;
  this->avgN   = other.avgN;
  this->pixSizePhys = other.pixSizePhys; // in units of [10^14 cm]
  this->convolved   = other.convolved;

  this->data = (double*) calloc(this->Nx*this->Ny,sizeof(double));
  for(long i=0;i<this->Nx*this->Ny;i++){
    this->data[i] = other.data[i];
  }
}


void MagnificationMap::convolve(Kernel* kernel,EffectiveMap* emap){
  cufftDoubleReal dum1,dum2;
  
  // Check if "kernel", which is a "profile" variable has the same dimension as the map

  //Fourier transform map
  cufftDoubleComplex* Fmap = (cufftDoubleComplex*) calloc(this->Nx*(this->Ny/2+1),sizeof(cufftDoubleComplex));
  myfft2d_r2c(this->Nx,this->Ny,this->data,Fmap);
  //Fourier transform kernel
  cufftDoubleComplex* Fkernel = (cufftDoubleComplex*) calloc(this->Nx*(this->Ny/2+1),sizeof(cufftDoubleComplex));
  myfft2d_r2c(this->Nx,this->Ny,kernel->data,Fkernel);
  //Multiply kernel and map
  for(long i=0;i<this->Nx*(this->Ny/2+1);i++){
    dum1 = (cufftDoubleReal) (Fmap[i].x*Fkernel[i].x - Fmap[i].y*Fkernel[i].y);
    dum2 = (cufftDoubleReal) (Fmap[i].x*Fkernel[i].y + Fmap[i].y*Fkernel[i].x);
    Fmap[i].x = dum1;
    Fmap[i].y = dum2;
  }
  //Inverse Fourier transform
  cufftDoubleReal* cmap = (cufftDoubleReal*) calloc(this->Nx*this->Ny,sizeof(cufftDoubleReal));
  myfft2d_c2r(this->Nx,this->Ny,Fmap,cmap);

  free(Fmap);
  free(Fkernel);

  //Normalize convolved map and crop to emap
  double norm = (double) (this->Nx*this->Ny);
  for(int i=0;i<emap->Ny;i++){
    for(int j=0;j<emap->Nx;j++){
      emap->data[i*emap->Nx+j] = (double) (cmap[emap->top*this->Nx+emap->left+i*this->Nx+j]/norm);
    }
  }

  this->convolved = true;
  free(cmap);
}


Mpd MagnificationMap::getFullMpd(){
  if( this->convolved ){
    std::cout << "Map is convolved. It has to be in ray counts in order to use this function." << std::endl;
    throw "This is an exception!";
  } else {
    double muth   = fabs(1.0/(pow(1.0-this->k,2)-pow(this->g,2)));

    thrust::device_vector<int> counts;
    thrust::device_vector<double> bins;
    thrust::device_vector<double> data(this->data,this->data+this->Nx*this->Ny);
    thrust::sort(data.begin(),data.end());
    
    int num_bins = thrust::inner_product(data.begin(),data.end()-1,data.begin()+1,int(1),thrust::plus<int>(),thrust::not_equal_to<double>());
    counts.resize(num_bins);
    bins.resize(num_bins);
    thrust::reduce_by_key(data.begin(),data.end(),thrust::constant_iterator<int>(1),bins.begin(),counts.begin());
    thrust::host_vector<int> hcounts(counts);
    thrust::host_vector<double> hbins(bins);
    
    Mpd theMpd(hcounts.size());
    for(unsigned int i=0;i<hcounts.size();i++){
      theMpd.counts[i] = (double) (hcounts[i])/(double) (this->Nx*this->Ny);
      theMpd.bins[i]   = ((double) (hbins[i]));
    }
    return theMpd; 
  }
}


Mpd MagnificationMap::getBinnedMpd(int Nbins){
  // creating bins which are evenly spaced in log space
  double min = 0.02;
  double max = 200;


  double logmin  = log10(min);
  double logmax  = log10(max);
  double logdbin = (logmax-logmin)/Nbins;
  double* bins   = (double*) calloc(Nbins,sizeof(double));
  for(int i=0;i<Nbins;i++){
    bins[i] = pow(10,logmin+(i+1)*logdbin);
  }

  thrust::device_vector<int>    counts(Nbins);
  thrust::device_vector<double> dbins(bins,bins+Nbins);
  thrust::device_vector<double> data(this->data,this->data+this->Nx*this->Ny);
  thrust::sort(data.begin(),data.end());

  // For the following lines to work I need to compile using the flag: --expt-extended-lambda
  //  auto getLog10LambdaFunctor = [=]  __device__ (double x) {return log10(x);};
  //  thrust::transform(data.begin(),data.end(),data.begin(),getLog10LambdaFunctor);

  double range[2] = {min,max};
  thrust::device_vector<double> drange(range,range+2);
  thrust::device_vector<int>    dirange(2);
  thrust::lower_bound(data.begin(),data.end(),drange.begin(),drange.end(),dirange.begin());
  thrust::host_vector<int> hirange(dirange);
  //  std::cout << hirange[0] << " " << hirange[1] << std::endl;

  thrust::upper_bound(data.begin() + hirange[0],data.begin() + hirange[1],dbins.begin(),dbins.end(),counts.begin());
  //  thrust::upper_bound(data.begin(),data.end(),dbins.begin(),dbins.end(),counts.begin());
  thrust::adjacent_difference(counts.begin(),counts.end(),counts.begin());
  thrust::host_vector<int>    hcounts(counts);

  Mpd theMpd(hcounts.size());
  for(unsigned int i=0;i<hcounts.size();i++){
    theMpd.counts[i] = (double) (hcounts[i]) /(double) (this->Nx*this->Ny);
    theMpd.bins[i]   = (double) bins[i];
  }
  free(bins);
  return theMpd;
}


int MagnificationMap::myfft2d_r2c(int Nx,int Ny,cufftDoubleReal* data,cufftDoubleComplex* Fdata){
  cufftHandle plan;
  cufftDoubleReal* data_GPU;
  cufftDoubleComplex* Fdata_GPU;

  //allocate and transfer memory to the GPU
  cudaMalloc( (void**) &data_GPU, Nx*Ny*sizeof(cufftDoubleReal));
  cudaMemcpy( data_GPU, data, Nx*Ny*sizeof(cufftDoubleReal), cudaMemcpyHostToDevice);
  cudaMalloc( (void**) &Fdata_GPU, Nx*(Ny/2+1)*sizeof(cufftDoubleComplex));

  //do the fourier transform on the GPU
  cufftPlan2d(&plan,Nx,Ny,CUFFT_D2Z);
  cufftExecD2Z(plan, data_GPU, Fdata_GPU);
  //  cudaDeviceSynchronize();
  cudaThreadSynchronize();
  cufftDestroy(plan);

  //copy back results
  cudaMemcpy(Fdata, Fdata_GPU, Nx*(Ny/2+1)*sizeof(cufftDoubleComplex), cudaMemcpyDeviceToHost);
  cudaFree(data_GPU);
  cudaFree(Fdata_GPU);

  return 0;
}


int MagnificationMap::myfft2d_c2r(int Nx, int Ny, cufftDoubleComplex* Fdata, cufftDoubleReal* data){
  cufftHandle plan;
  cufftDoubleComplex* Fdata_GPU;
  cufftDoubleReal* data_GPU;
  
  //allocate and transfer memory
  cudaMalloc((void**) &Fdata_GPU, Nx*(Ny/2+1)*sizeof(cufftDoubleComplex));
  cudaMemcpy(Fdata_GPU, Fdata, Nx*(Ny/2+1)*sizeof(cufftDoubleComplex), cudaMemcpyHostToDevice);
  cudaMalloc((void**) &data_GPU, Nx*Ny*sizeof(cufftDoubleReal));

  //do the inverse fourier transform on the GPU
  cufftPlan2d(&plan,Nx,Ny,CUFFT_Z2D) ;
  cufftExecZ2D(plan, Fdata_GPU, data_GPU);
  //  cudaDeviceSynchronize();
  cudaThreadSynchronize();
  cufftDestroy(plan);
  
  //copy back results
  cudaMemcpy(data, data_GPU, Nx*Ny*sizeof(cufftDoubleReal), cudaMemcpyDeviceToHost);
  cudaFree(data_GPU);
  cudaFree(Fdata_GPU);
  
  return 0;
}


void MagnificationMap::writeMapPNG(const std::string filename,int sampling){
  // read, sample, and scale map
  int nNx = (int) (this->Nx/sampling);
  int nNy = (int) (this->Ny/sampling);
  int* colors = (int*) calloc(nNx*nNy,sizeof(int));
  this->scaleMap(colors,sampling);
  
  // read rgb values from table file (or select them from a stored list of rgb color tables)
  int* rgb = (int*) calloc(3*256,sizeof(int));
  readRGB("rgb.dat",rgb);

  // write image
  writeImage(filename,nNx,nNy,colors,rgb);

  free(colors);
  free(rgb);
}


void MagnificationMap::scaleMap(int* colors,int sampling){
  double scale_max = 1.6;
  double scale_min = -1.6;
  double scale_fac = 255/(fabs(scale_min) + scale_max);
  double dum,dum2;

  long count = 0;
  for(int i=0;i<this->Ny;i+=sampling){
    for(int j=0;j<this->Nx;j+=sampling){
      dum = log10(this->data[i*this->Nx+j]);
      if( dum < scale_min ){
	dum = scale_min;
      }
      if( dum > scale_max ){
	dum = scale_max;
      }
      
      dum2 = (dum + fabs(scale_min))*scale_fac;
      colors[count] = (int) round(dum2);
      count++;
    }
  }
}


void MagnificationMap::readRGB(const std::string filename,int* rgb){
  int r,g,b;
  std::ifstream istr(filename);
  
  for(int i=0;i<256;i++){
    istr >> r >> g >> b;
    rgb[i*3] = r;
    rgb[i*3 + 1] = g;
    rgb[i*3 + 2] = b;
  }
}


void MagnificationMap::writeImage(const std::string filename, int width,int height,int* colors,int* rgb){
  FILE* fp            = fopen(filename.data(), "wb");
  png_structp png_ptr = png_create_write_struct(PNG_LIBPNG_VER_STRING, NULL, NULL, NULL);
  png_infop info_ptr  = png_create_info_struct(png_ptr);
  
  png_init_io(png_ptr, fp);
  png_set_IHDR(png_ptr, info_ptr, width, height, 8, PNG_COLOR_TYPE_RGB, PNG_INTERLACE_NONE, PNG_COMPRESSION_TYPE_BASE, PNG_FILTER_TYPE_BASE);
  png_write_info(png_ptr, info_ptr);
  
  
  png_bytep row = (png_bytep) malloc(3 * width * sizeof(png_byte));
  int cindex;
  for(int j=0;j<height;j++) {
    for(int i=0;i<width;i++) {
      cindex = colors[j*width+i];
      
      row[i*3]   = rgb[cindex*3];
      row[i*3+1] = rgb[cindex*3 + 1];
      row[i*3+2] = rgb[cindex*3 + 2];
    }
    png_write_row(png_ptr, row);
  }
  png_write_end(png_ptr, NULL);
  
  
  fclose(fp);
  png_free_data(png_ptr,info_ptr,PNG_FREE_ALL,-1);
  png_destroy_write_struct(&png_ptr, (png_infopp)NULL);
  free(row);
}






EffectiveMap::EffectiveMap(int offset,MagnificationMap* map){
  this->top    = offset;
  this->bottom = offset;
  this->left   = offset;
  this->right  = offset;

  this->pixSizePhys = map->pixSizePhys;
  this->Nx = map->Nx - 2*offset;
  this->Ny = map->Ny - 2*offset;
  this->data = (double*) calloc(this->Nx*this->Ny,sizeof(double));
  this->width = map->width*this->Nx/map->Nx;
  this->height = map->height*this->Ny/map->Ny;

  this->k = map->k;
  this->g = map->g;
  this->s = map->s;
  this->avgmu = map->avgmu;
  this->avgN = map->avgN;

  this->convolved = true;
}

EffectiveMap::EffectiveMap(int top,int bottom,int left,int right,MagnificationMap* map){
  this->top    = top;
  this->bottom = bottom;
  this->left   = left;
  this->right  = right;

  this->pixSizePhys = map->pixSizePhys;
  this->Nx = map->Nx - left - right;
  this->Ny = map->Ny - top - bottom;
  this->data = (double*) calloc(this->Nx*this->Ny,sizeof(double));
  this->width = map->width*this->Nx/map->Nx;
  this->height = map->height*this->Ny/map->Ny;

  this->k = map->k;
  this->g = map->g;
  this->s = map->s;
  this->avgmu = map->avgmu;
  this->avgN = map->avgN;

  this->convolved = true;
}