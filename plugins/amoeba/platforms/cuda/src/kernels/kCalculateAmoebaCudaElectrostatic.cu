//-----------------------------------------------------------------------------------------

//-----------------------------------------------------------------------------------------

#include "amoebaGpuTypes.h"
#include "amoebaCudaKernels.h"
#include "kCalculateAmoebaCudaUtilities.h"

//#define AMOEBA_DEBUG

static __constant__ cudaGmxSimulation cSim;
static __constant__ cudaAmoebaGmxSimulation cAmoebaSim;

void SetCalculateAmoebaElectrostaticSim(amoebaGpuContext amoebaGpu)
{
    cudaError_t status;
    gpuContext gpu = amoebaGpu->gpuContext;
    status         = cudaMemcpyToSymbol(cSim, &gpu->sim, sizeof(cudaGmxSimulation));    
    RTERROR(status, "SetCalculateAmoebaElectrostaticSim: cudaMemcpyToSymbol: SetSim copy to cSim failed");
    status         = cudaMemcpyToSymbol(cAmoebaSim, &amoebaGpu->amoebaSim, sizeof(cudaAmoebaGmxSimulation));    
    RTERROR(status, "SetCalculateAmoebaElectrostaticSim: cudaMemcpyToSymbol: SetSim copy to cAmoebaSim failed");
}

void GetCalculateAmoebaElectrostaticSim(amoebaGpuContext amoebaGpu)
{
    cudaError_t status;
    gpuContext gpu = amoebaGpu->gpuContext;
    status = cudaMemcpyFromSymbol(&gpu->sim, cSim, sizeof(cudaGmxSimulation));    
    RTERROR(status, "GetCalculateAmoebaElectrostaticSim: cudaMemcpyFromSymbol: SetSim copy from cSim failed");
    status = cudaMemcpyFromSymbol(&amoebaGpu->amoebaSim, cAmoebaSim, sizeof(cudaAmoebaGmxSimulation));    
    RTERROR(status, "GetCalculateAmoebaElectrostaticSim: cudaMemcpyFromSymbol: SetSim copy from cAmoebaSim failed");
}

static int const PScaleIndex            =  0; 
static int const DScaleIndex            =  1; 
static int const UScaleIndex            =  2; 
static int const MScaleIndex            =  3;
static int const Scale3Index            =  4;
static int const Scale5Index            =  5;
static int const Scale7Index            =  6;
static int const Scale9Index            =  7;
static int const Ddsc30Index            =  8;
//static int const Ddsc31Index            =  9;
//static int const Ddsc32Index            = 10; 
static int const Ddsc50Index            = 11;
//static int const Ddsc51Index            = 12;
//static int const Ddsc52Index            = 13; 
static int const Ddsc70Index            = 14;
//static int const Ddsc71Index            = 15;
//static int const Ddsc72Index            = 16;
static int const LastScalingIndex       = 17;

#define DOT3_4(u,v) ((u[0])*(v[0]) + (u[1])*(v[1]) + (u[2])*(v[2]))

#define MATRIXDOT31(u,v) u[0]*v[0] + u[1]*v[1] + u[2]*v[2] + \
  u[3]*v[3] + u[4]*v[4] + u[5]*v[5] + \
  u[6]*v[6] + u[7]*v[7] + u[8]*v[8]

#define DOT31(u,v) ((u[0])*(v[0]) + (u[1])*(v[1]) + (u[2])*(v[2]))

#define i35 0.257142857f
#define one 1.0f

__device__ void acrossProductVector3(   float* vectorX, float* vectorY, float* vectorZ ){
    vectorZ[0]  = vectorX[1]*vectorY[2] - vectorX[2]*vectorY[1];
    vectorZ[1]  = vectorX[2]*vectorY[0] - vectorX[0]*vectorY[2];
    vectorZ[2]  = vectorX[0]*vectorY[1] - vectorX[1]*vectorY[0];
}

__device__ void amatrixProductVector3(   float* matrixX, float* vectorY, float* vectorZ ){
    vectorZ[0]  = matrixX[0]*vectorY[0] + matrixX[3]*vectorY[1] + matrixX[6]*vectorY[2];
    vectorZ[1]  = matrixX[1]*vectorY[0] + matrixX[4]*vectorY[1] + matrixX[7]*vectorY[2];
    vectorZ[2]  = matrixX[2]*vectorY[0] + matrixX[5]*vectorY[1] + matrixX[8]*vectorY[2];
}

__device__ void amatrixCrossProductMatrix3( float* matrixX, float* matrixY, float* vectorZ ){
  
    float* xPtr[3];
    float* yPtr[3];
        
    xPtr[0]    = matrixX;
    xPtr[1]    = matrixX + 3;
    xPtr[2]    = matrixX + 6;
    
    yPtr[0]    = matrixY;
    yPtr[1]    = matrixY + 3;
    yPtr[2]    = matrixY + 6;
          
    vectorZ[0] = DOT31( xPtr[1], yPtr[2] ) - DOT31( xPtr[2], yPtr[1] );
    vectorZ[1] = DOT31( xPtr[2], yPtr[0] ) - DOT31( xPtr[0], yPtr[2] );
    vectorZ[2] = DOT31( xPtr[0], yPtr[1] ) - DOT31( xPtr[1], yPtr[0] );
  
}

struct ElectrostaticParticle {

    // coordinates charge

    float x;
    float y;
    float z;
    float q;

    // lab frame dipole

    float labFrameDipole[3];

    // lab frame quadrupole

    float labFrameQuadrupole[9];

    // induced dipole

    float inducedDipole[3];

    // polar induced dipole

    float inducedDipoleP[3];

    // scaling factors

    float thole;
    float damp;

    float force[3];

    float torque[3];
    float padding;

};

__device__ void calculateElectrostaticPairIxn_kernel( ElectrostaticParticle& atomI,   ElectrostaticParticle& atomJ,
                                                      float scalingDistanceCutoff,   float* scalingFactors,
                                                      float*  outputForce,           float  outputTorque[2][3],
                                                      float* energy
#ifdef AMOEBA_DEBUG
                                                      ,float4* debugArray 
#endif
 ){
  
    float deltaR[3];
    
    // ---------------------------------------------------------------------------------------
    
    // ---------------------------------------------------------------------------------------

    float* ddsc3                    =  scalingFactors + Ddsc30Index;
    float* ddsc5                    =  scalingFactors + Ddsc50Index;
    float* ddsc7                    =  scalingFactors + Ddsc70Index;

    deltaR[0]                       = atomJ.x - atomI.x;
    deltaR[1]                       = atomJ.y - atomI.y;
    deltaR[2]                       = atomJ.z - atomI.z;

    float r2                        = DOT31( deltaR, deltaR );
    float r                         = sqrtf( r2 );
    float rr1                       = 1.0f/r;
    float rr2                       = rr1*rr1;
    float rr3                       = rr1*rr2;
    float rr5                       = 3.0f*rr3*rr2;
    float rr7                       = 5.0f*rr5*rr2;
    float rr9                       = 7.0f*rr7*rr2;
    float rr11                      = 9.0f*rr9*rr2;

    //-------------------------------------------

    if( atomI.damp != 0.0f && atomJ.damp != 0.0 && r < scalingDistanceCutoff ){
   
        float distanceIJ, r2I;
        distanceIJ                    = r;
        r2I                           = rr2;
        
        float ratio                   = distanceIJ/(atomI.damp*atomJ.damp);
        float pGamma                  = atomJ.thole > atomI.thole ? atomI.thole : atomJ.thole;

        float damp                          = ratio*ratio*ratio*pGamma;
        float dampExp                 = expf( -damp );
        float damp1                   = damp + one;
        float damp2                   = damp*damp;
        float damp3                   = damp2*damp;

        scalingFactors[Scale3Index]   = one - dampExp;
        scalingFactors[Scale5Index]   = one - damp1*dampExp;
        scalingFactors[Scale7Index]   = one - ( damp1 + 0.6f*damp2)*dampExp;
        scalingFactors[Scale9Index]   = one - ( damp1 + ( 2.0f*damp2 + damp3 )*i35)*dampExp;

        float factor                  = 3.0f*damp*dampExp*r2I;
        float factor7                 = -0.2f + 0.6f*damp;
        
        for( int ii = 0; ii < 3; ii++ ){
            scalingFactors[Ddsc30Index + ii] = factor*deltaR[ii];
            scalingFactors[Ddsc50Index + ii] = scalingFactors[Ddsc30Index + ii]*damp;
            scalingFactors[Ddsc70Index + ii] = scalingFactors[Ddsc50Index + ii]*factor7;
        }

    }

    float scaleI[3];
    float dsc[3];
    float psc[3];
      
    for( int ii = 0; ii < 3; ii++ ){
        scaleI[ii] = scalingFactors[Scale3Index+ii]*scalingFactors[UScaleIndex];
        dsc[ii]    = scalingFactors[Scale3Index+ii]*scalingFactors[DScaleIndex];
        psc[ii]    = scalingFactors[Scale3Index+ii]*scalingFactors[PScaleIndex];
    }
                       
    float sc[11];
    float sci[9];
    float scip[9];
    float qIr[3], qJr[3];

    amatrixProductVector3( atomJ.labFrameQuadrupole,      deltaR,      qJr);
    amatrixProductVector3( atomI.labFrameQuadrupole,      deltaR,      qIr);

    sc[2]     = DOT3_4(        atomI.labFrameDipole,  atomJ.labFrameDipole );
    sc[3]     = DOT3_4(        atomI.labFrameDipole,  deltaR  );
    sc[4]     = DOT3_4(        atomJ.labFrameDipole,  deltaR  );
    
    sc[5]     = DOT3_4(        qIr, deltaR  );
    sc[6]     = DOT3_4(        qJr, deltaR  );
    
    sc[7]     = DOT3_4(        qIr, atomJ.labFrameDipole );
    sc[8]     = DOT3_4(        qJr, atomI.labFrameDipole );
    
    sc[9]     = DOT3_4(        qIr, qJr );
    
    sc[10]    = MATRIXDOT31( atomI.labFrameQuadrupole, atomJ.labFrameQuadrupole );
    
    sci[1]    = DOT3_4(        atomI.inducedDipole,  atomJ.labFrameDipole ) +
                DOT3_4(        atomJ.inducedDipole,  atomI.labFrameDipole );
    
    sci[2]    = DOT3_4(        atomI.inducedDipole,  atomJ.inducedDipole );
    
    sci[3]    = DOT3_4(        atomI.inducedDipole,  deltaR  );
    sci[4]    = DOT3_4(        atomJ.inducedDipole,  deltaR  );
    
    sci[7]    = DOT3_4(        qIr, atomJ.inducedDipole );
    sci[8]    = DOT3_4(        qJr, atomI.inducedDipole );
    
    scip[1]   = DOT3_4(        atomI.inducedDipoleP, atomJ.labFrameDipole ) +
                DOT3_4(        atomJ.inducedDipoleP, atomI.labFrameDipole );
    
    scip[2]   = DOT3_4(        atomI.inducedDipole,  atomJ.inducedDipoleP) +
                DOT3_4(        atomJ.inducedDipole,  atomI.inducedDipoleP);
    
    scip[3]   = DOT3_4(        atomI.inducedDipoleP, deltaR );
    scip[4]   = DOT3_4(        atomJ.inducedDipoleP, deltaR );
    
    scip[7]   = DOT3_4(        qIr, atomJ.inducedDipoleP );
    scip[8]   = DOT3_4(        qJr, atomI.inducedDipoleP );

    float findmp[3];
    float scaleF         = 0.5f*scalingFactors[UScaleIndex];
    float inducedFactor3 = scip[2]*rr3*scaleF;
    float inducedFactor5 = (sci[3]*scip[4]+scip[3]*sci[4])*rr5*scaleF;
    findmp[0]            = inducedFactor3*ddsc3[0] - inducedFactor5*ddsc5[0];
    findmp[1]            = inducedFactor3*ddsc3[1] - inducedFactor5*ddsc5[1];
    findmp[2]            = inducedFactor3*ddsc3[2] - inducedFactor5*ddsc5[2];

    float gli[8];
    gli[1]               = atomJ.q*sci[3] - atomI.q*sci[4];
    gli[2]               = -sc[3]*sci[4] - sci[3]*sc[4];
    gli[3]               = sci[3]*sc[6] - sci[4]*sc[5];
    gli[6]               = sci[1];
    gli[7]               = 2.0f*(sci[7]-sci[8]);
    
    float glip[8];
    glip[1]              = atomJ.q*scip[3] - atomI.q*scip[4];
    glip[2]              = -sc[3]*scip[4] - scip[3]*sc[4];
    glip[3]              = scip[3]*sc[6] - scip[4]*sc[5];
    glip[6]              = scip[1];
    glip[7]              = 2.0f*(scip[7]-scip[8]);
    
    float fridmp[3];
    float factor3, factor5, factor7;
    
    if( scalingFactors[PScaleIndex] == 1.0f && scalingFactors[PScaleIndex] == 1.0f ){
        factor3 = rr3*( gli[1]  +  gli[6]  + glip[1]  + glip[6] );
        factor5 = rr5*( gli[2]  +  gli[7]  + glip[2]  + glip[7] );
        factor7 = rr7*( gli[3]  + glip[3] );
    } else {
        factor3 = rr3*(( gli[1]  +  gli[6])*scalingFactors[PScaleIndex] +
                       (glip[1]  + glip[6])*scalingFactors[DScaleIndex]);
   
       factor5 = rr5*(( gli[2]  +  gli[7])*scalingFactors[PScaleIndex] +
                      (glip[2]  + glip[7])*scalingFactors[DScaleIndex]);
   
       factor7 = rr7*( gli[3]*scalingFactors[PScaleIndex] + glip[3]*scalingFactors[DScaleIndex]);
    }
      
    fridmp[0] = 0.5f*(factor3*ddsc3[0] + factor5*ddsc5[0] + factor7*ddsc7[0]);
    fridmp[1] = 0.5f*(factor3*ddsc3[1] + factor5*ddsc5[1] + factor7*ddsc7[1]);
    fridmp[2] = 0.5f*(factor3*ddsc3[2] + factor5*ddsc5[2] + factor7*ddsc7[2]);
      
    float gl[9];
    
    gl[0] = atomI.q*atomJ.q;
    gl[1] = atomJ.q*sc[3] - atomI.q*sc[4];
    gl[2] = atomI.q*sc[6] + atomJ.q*sc[5] - sc[3]*sc[4];
    
    gl[3] = sc[3]*sc[6] - sc[4]*sc[5];
    gl[4] = sc[5]*sc[6];
    gl[6] = sc[2];
    gl[7] = 2.0f*(sc[7]-sc[8]);
    gl[8] = 2.0f*sc[10];
    gl[5] = -4.0f*sc[9];
    
    float gf[8];
    gf[1] = rr3*gl[0] + rr5*(gl[1]+gl[6]) + rr7*(gl[2]+gl[7]+gl[8]) + rr9*(gl[3]+gl[5]) + rr11*gl[4];
    gf[2] = -atomJ.q*rr3 + sc[4]*rr5 - sc[6]*rr7;
    gf[3] =  atomI.q*rr3 + sc[3]*rr5 + sc[5]*rr7;
    gf[4] = 2.0f*rr5;
    gf[5] = 2.0f*(-atomJ.q*rr5+sc[4]*rr7-sc[6]*rr9);
    gf[6] = 2.0f*(-atomI.q*rr5-sc[3]*rr7-sc[5]*rr9);
    gf[7] = 4.0f*rr7;

    // energy

    float conversionFactor   = (cAmoebaSim.electric/cAmoebaSim.dielec);
    float em                 = scalingFactors[MScaleIndex]*(rr1*gl[0] + rr3*(gl[1]+gl[6]) + rr5*(gl[2]+gl[7]+gl[8]) + rr7*(gl[3]+gl[5]) + rr9*gl[4]);
    float ei                 = 0.5f*(rr3*(gli[1]+gli[6])*psc[0] + rr5*(gli[2]+gli[7])*psc[1] + rr7*gli[3]*psc[2]);
    *energy                  = conversionFactor*(em+ei);
    
#ifdef AMOEBA_DEBUG
#if 0
if( 1 ){
    int debugIndex           = 0;
    debugArray[debugIndex].x = conversionFactor*em;
    debugArray[debugIndex].y = conversionFactor*ei;
    debugArray[debugIndex].z = rr1;
    debugArray[debugIndex].w = rr3;

    debugIndex++;
    debugArray[debugIndex].x = gl[0];
    debugArray[debugIndex].y = gl[1];
    debugArray[debugIndex].z = gl[6];
    debugArray[debugIndex].w = gl[2];

    debugIndex++;
    debugArray[debugIndex].x = gli[1];
    debugArray[debugIndex].y = gli[3];
    debugArray[debugIndex].z = gli[2];
    debugArray[debugIndex].w = gli[7];

    debugIndex++;
    debugArray[debugIndex].x = psc[0];
    debugArray[debugIndex].y = psc[1];
    debugArray[debugIndex].z = psc[2];
    debugArray[debugIndex].w = scalingFactors[MScaleIndex];

}
#endif
#endif

    float ftm2[3];
    float temp1[3],temp2[3],temp3[3];
    float qIqJr[3], qJqIr[3], qIdJ[3], qJdI[3];
    amatrixProductVector3( atomI.labFrameQuadrupole,      atomJ.labFrameDipole,     qIdJ );//MK
    amatrixProductVector3( atomJ.labFrameQuadrupole,      atomI.labFrameDipole,     qJdI );//MK

    amatrixProductVector3( atomI.labFrameQuadrupole,      qJr,    qIqJr );//MK
    amatrixProductVector3( atomJ.labFrameQuadrupole,      qIr,    qJqIr );//MK
    amatrixProductVector3( atomJ.labFrameQuadrupole,      qIr,    temp1 );
    amatrixProductVector3( atomJ.labFrameQuadrupole,      atomI.labFrameDipole,     temp2 );

    for( int ii = 0; ii < 3; ii++ ){
        ftm2[ii] = gf[1]*deltaR[ii]                             +
                   gf[2]*atomI.labFrameDipole[ii]     + gf[3]*atomJ.labFrameDipole[ii]  +
                   gf[4]*(temp2[ii]  - qIdJ[ii])                    +
                   gf[5]*qIr[ii]    + gf[6]*qJr[ii] +
                   gf[7]*(qIqJr[ii] + temp1[ii]);
    
    }

    // get the induced force;

    // intermediate variables for the induced-permanent terms;
    
    float gfi[7];
    gfi[1] = rr5*0.5f*((gli[1]+gli[6])*psc[0] + (glip[1]+glip[6])*dsc[0] + scip[2]*scaleI[0]) + rr7*((gli[7]+gli[2])*psc[1] + (glip[7]+glip[2])*dsc[1] -
                                                       (sci[3]*scip[4]+scip[3]*sci[4])*scaleI[1])*0.5f + rr9*(gli[3]*psc[2]+glip[3]*dsc[2])*0.5f;
    gfi[2] = -rr3*atomJ.q + rr5*sc[4] - rr7*sc[6];
    gfi[3] = rr3*atomI.q  + rr5*sc[3] + rr7*sc[5];
    gfi[4] = 2.0f*rr5;
    gfi[5] = rr7* (sci[4]*psc[2] + scip[4]*dsc[2]);
    gfi[6] = -rr7*(sci[3]*psc[2] + scip[3]*dsc[2]);


    float ftm2i[3];
    float temp4[3];
    float temp5[3];
    float temp6[3];
    float temp7[3];
    float temp8[3];
    float temp9[3];
    float temp10[3];
    float temp11[3];
    float temp12[3];
    float temp13[3];
    float temp14[3];
    float temp15[3];
    float qIuJp[3], qJuIp[3];
    float qIuJ[3], qJuI[3];

    amatrixProductVector3(atomJ.labFrameQuadrupole,      atomI.inducedDipoleP,    temp4);

    amatrixProductVector3(atomI.labFrameQuadrupole,      atomJ.inducedDipoleP,    qIuJp);//MK
    amatrixProductVector3(atomJ.labFrameQuadrupole,      atomI.inducedDipoleP,    qJuIp);//MK
    amatrixProductVector3(atomJ.labFrameQuadrupole,      atomI.inducedDipole ,    qJuI);//MK

    amatrixProductVector3(atomJ.labFrameQuadrupole,      atomI.inducedDipole,    temp5);
    amatrixProductVector3(atomI.labFrameQuadrupole,      atomJ.inducedDipole ,     qIuJ);//MK

    float temp1_0,temp2_0,temp3_0;
    for( int ii = 0; ii < 3; ii++ ){
        temp1_0 = gfi[1]*deltaR[ii] +
                  0.5f*(-rr3*atomJ.q*(atomI.inducedDipole[ii]*psc[0] + atomI.inducedDipoleP[ii]*dsc[0]) +
                  rr5*sc[4]*(atomI.inducedDipole[ii]*psc[1] + atomI.inducedDipoleP[ii]*dsc[1]) -
                  rr7*sc[6]*(atomI.inducedDipole[ii]*psc[2] + atomI.inducedDipoleP[ii]*dsc[2])) ;

        temp2_0 = (rr3*atomI.q*(atomJ.inducedDipole[ii]*psc[0]+atomJ.inducedDipoleP[ii]*dsc[0]) +
                   rr5*sc[3]*(atomJ.inducedDipole[ii]*psc[1] +atomJ.inducedDipoleP[ii]*dsc[1]) +
                   rr7*sc[5]*(atomJ.inducedDipole[ii]*psc[2] +atomJ.inducedDipoleP[ii]*dsc[2]))*0.5f +
                   rr5*scaleI[1]*(sci[4]*atomI.inducedDipoleP[ii]+scip[4]*atomI.inducedDipole[ii] +
                   sci[3]*atomJ.inducedDipoleP[ii]+scip[3]*atomJ.inducedDipole[ii])*0.5f ;

        temp3_0 = 0.5f*(sci[4]*psc[1]+scip[4]*dsc[1])*rr5*atomI.labFrameDipole[ii] +
                  0.5f*(sci[3]*psc[1]+scip[3]*dsc[1])*rr5*atomJ.labFrameDipole[ii] +
                  0.5f*gfi[4]*((temp5[ii]-qIuJ[ii])*psc[1] +
                  (temp4[ii]-qIuJp[ii])*dsc[1]) + gfi[5]*qIr[ii] + gfi[6]*qJr[ii];
        ftm2i[ii] = temp1_0 + temp2_0 + temp3_0;
    }

    // handle of scaling for partially excluded interactions;
    // correction to convert mutual to direct polarization force;
    
    ftm2i[0] -= (fridmp[0] + findmp[0]);
    ftm2i[1] -= (fridmp[1] + findmp[1]);
    ftm2i[2] -= (fridmp[2] + findmp[2]);
    
    // now perform the torque calculation;
    // intermediate terms for torque between multipoles i and j;
    
    float gti[7];
    gti[2] = 0.5f*(sci[4]*psc[1]+scip[4]*dsc[1])*rr5;
    gti[3] = 0.5f*(sci[3]*psc[1]+scip[3]*dsc[1])*rr5;
    gti[4] = gfi[4];
    gti[5] = gfi[5];
    gti[6] = gfi[6];

    // get the permanent (ttm2, ttm3) and induced interaction torques (ttm2i, ttm3i)
    
    float ttm2[3];
    float ttm2i[3];
    float ttm3[3];
    float ttm3i[3];
    acrossProductVector3(atomI.labFrameDipole,      atomJ.labFrameDipole,      temp1);
    acrossProductVector3(atomI.labFrameDipole,      atomJ.inducedDipole ,      temp2);
    acrossProductVector3(atomI.labFrameDipole,      atomJ.inducedDipoleP,     temp3);
    acrossProductVector3(atomI.labFrameDipole,      deltaR,       temp4);
    acrossProductVector3(deltaR,       qIuJp,   temp5);
    acrossProductVector3(deltaR,       qIr,     temp6);
    acrossProductVector3(deltaR,       qIuJ,    temp7);
    acrossProductVector3(atomJ.inducedDipole ,     qIr,     temp8);
    acrossProductVector3(atomJ.inducedDipoleP,     qIr,     temp9);
    acrossProductVector3(atomI.labFrameDipole,     qJr,     temp10);
    acrossProductVector3(atomJ.labFrameDipole,     qIr,     temp11);
    acrossProductVector3(deltaR,       qIqJr,   temp12);
    acrossProductVector3(deltaR,       qIdJ,    temp13);

    amatrixCrossProductMatrix3(atomI.labFrameQuadrupole,      atomJ.labFrameQuadrupole,      temp14);
    acrossProductVector3(qJr, qIr,     temp15);

    // unroll?

    for( int ii = 0; ii < 3; ii++ ){
       ttm2[ii]  = -rr3*temp1[ii] + gf[2]*temp4[ii]-gf[5]*temp6[ii] +
                   gf[4]*(temp10[ii] + temp11[ii] + temp13[ii]-2.0f*temp14[ii]) -
                   gf[7]*(temp12[ii] + temp15[ii]);
    
       ttm2i[ii] = -rr3*(temp2[ii]*psc[0]+temp3[ii]*dsc[0])*0.5f +
                    gti[2]*temp4[ii] + gti[4]*((temp8[ii]+ temp7[ii])*psc[1] +
                    (temp9[ii] + temp5[ii])*dsc[1])*0.5f - gti[5]*temp6[ii];
    
    }

    acrossProductVector3(atomJ.labFrameDipole,      deltaR,       temp2  );
    acrossProductVector3(deltaR,       qJr,     temp3  );
    acrossProductVector3(atomI.labFrameDipole,      qJr,     temp4  );
    acrossProductVector3(atomJ.labFrameDipole,      qIr,     temp5  );
    acrossProductVector3(deltaR,       qJdI,    temp6  );
    acrossProductVector3(deltaR,       qJqIr,   temp7  );
    acrossProductVector3(qJr,     qIr,     temp8  ); // _qJrxqIr
    acrossProductVector3(atomJ.labFrameDipole,      atomI.inducedDipole ,      temp9  ); // _dJxuI
    acrossProductVector3(atomJ.labFrameDipole,      atomI.inducedDipoleP,     temp10 ); // _dJxuIp

    acrossProductVector3(atomI.inducedDipoleP,     qJr,     temp11 ); // _uIxqJrp
    acrossProductVector3(atomI.inducedDipole ,     qJr,     temp12 ); // _uIxqJr
    acrossProductVector3(deltaR,       qJuIp,   temp13 ); // _rxqJuIp
    acrossProductVector3(deltaR,       qJuI,    temp15 ); // _rxqJuI

    // unroll?

    for( int ii = 0; ii < 3; ii++ ){
    
       ttm3[ii] = rr3*temp1[ii] +
                  gf[3]*temp2[ii] - gf[6]*temp3[ii] - gf[4]*(temp4[ii] + temp5[ii] + temp6[ii] - 2.0f*temp14[ii]) - gf[7]*(temp7[ii] - temp8[ii]);

    
       ttm3i[ii] = -rr3*(temp9[ii]*psc[0]+ temp10[ii]*dsc[0])*0.5f +
                    gti[3]*temp2[ii] - 
                    gti[4]*((temp12[ii] + temp15[ii])*psc[1] +
                    (temp11[ii] + temp13[ii])*dsc[1])*0.5f - gti[6]*temp3[ii];
    }

    if( scalingFactors[MScaleIndex] < 1.0f ){
    
        ftm2[0] *= scalingFactors[MScaleIndex];
        ftm2[1] *= scalingFactors[MScaleIndex];
        ftm2[2] *= scalingFactors[MScaleIndex];
        
        ttm2[0] *= scalingFactors[MScaleIndex];
        ttm2[1] *= scalingFactors[MScaleIndex];
        ttm2[2] *= scalingFactors[MScaleIndex];
        
        ttm3[0] *= scalingFactors[MScaleIndex];
        ttm3[1] *= scalingFactors[MScaleIndex];
        ttm3[2] *= scalingFactors[MScaleIndex];
    
    }


#ifdef AMOEBA_DEBUG
#if 0
if( 0 ){
int debugIndex               = 0;
    debugArray[debugIndex].x = conversionFactor*ftm2[0];
    debugArray[debugIndex].y = conversionFactor*ftm2i[0];
    debugArray[debugIndex].z = conversionFactor*ttm3[0];
    debugArray[debugIndex].w = conversionFactor*ttm3i[0];

    debugIndex++;
    debugArray[debugIndex].x = temp1[0];
    debugArray[debugIndex].y = temp1[1];
    debugArray[debugIndex].z = temp1[2];
    debugArray[debugIndex].w = 1.0f;

    debugIndex++;
    debugArray[debugIndex].x = temp2[0];
    debugArray[debugIndex].y = temp2[1];
    debugArray[debugIndex].z = temp2[2];
    debugArray[debugIndex].w = 2.0f;

    debugIndex++;
    debugArray[debugIndex].x = temp3[0];
    debugArray[debugIndex].y = temp3[1];
    debugArray[debugIndex].z = temp3[2];
    debugArray[debugIndex].w = 3.0f;

    debugIndex++;
    debugArray[debugIndex].x = temp4[0];
    debugArray[debugIndex].y = temp4[1];
    debugArray[debugIndex].z = temp4[2];
    debugArray[debugIndex].w = 4.0f;

    debugIndex++;
    debugArray[debugIndex].x = temp5[0];
    debugArray[debugIndex].y = temp5[1];
    debugArray[debugIndex].z = temp5[2];
    debugArray[debugIndex].w = 5.0f;

    debugIndex++;
    debugArray[debugIndex].x = temp6[0];
    debugArray[debugIndex].y = temp6[1];
    debugArray[debugIndex].z = temp6[2];
    debugArray[debugIndex].w = 6.0f;

    debugIndex++;
    debugArray[debugIndex].x = temp14[0];
    debugArray[debugIndex].y = temp14[1];
    debugArray[debugIndex].z = temp14[2];
    debugArray[debugIndex].w = 14.0f;

    debugIndex++;
    debugArray[debugIndex].x = temp7[0];
    debugArray[debugIndex].y = temp7[1];
    debugArray[debugIndex].z = temp7[2];
    debugArray[debugIndex].w = 7.0f;


    debugIndex++;
    debugArray[debugIndex].x = temp8[0];
    debugArray[debugIndex].y = temp8[1];
    debugArray[debugIndex].z = temp8[2];
    debugArray[debugIndex].w = 8.0f;

    debugIndex++;
    debugArray[debugIndex].x = rr3;
    debugArray[debugIndex].y = gf[3];
    debugArray[debugIndex].z = gf[6];
    debugArray[debugIndex].w = 20.0f;

    debugIndex++;
    debugArray[debugIndex].x = gf[4];
    debugArray[debugIndex].y = gf[7];
    debugArray[debugIndex].z = 0.0f;
    debugArray[debugIndex].w = 21.0f;

    debugIndex++;
    debugArray[debugIndex].x = atomJ.labFrameDipole[0];
    debugArray[debugIndex].y = atomJ.labFrameDipole[1];
    debugArray[debugIndex].z = atomJ.labFrameDipole[2];
    debugArray[debugIndex].w = 22.0f;

    debugIndex++;
    debugArray[debugIndex].x = deltaR[0];
    debugArray[debugIndex].y = deltaR[1];
    debugArray[debugIndex].z = deltaR[2];
    debugArray[debugIndex].w = 23.0f;

}
#endif
#endif

    outputForce[0]        = -conversionFactor*(ftm2[0] + ftm2i[0]);
    outputForce[1]        = -conversionFactor*(ftm2[1] + ftm2i[1]);
    outputForce[2]        = -conversionFactor*(ftm2[2] + ftm2i[2]);
    
    outputTorque[0][0]    = conversionFactor*(ttm2[0] + ttm2i[0]); 
    outputTorque[0][1]    = conversionFactor*(ttm2[1] + ttm2i[1]); 
    outputTorque[0][2]    = conversionFactor*(ttm2[2] + ttm2i[2]); 

    outputTorque[1][0]    = conversionFactor*(ttm3[0] + ttm3i[0]); 
    outputTorque[1][1]    = conversionFactor*(ttm3[1] + ttm3i[1]); 
    outputTorque[1][2]    = conversionFactor*(ttm3[2] + ttm3i[2]); 

    return;

}

__device__ void loadElectrostaticShared( struct ElectrostaticParticle* sA, unsigned int atomI,
                                         float4* atomCoord, float* labFrameDipoleJ, float* labQuadrupole,
                                         float* inducedDipole, float* inducedDipolePolar, float2* dampingFactorAndThole )
{
    // coordinates & charge

    sA->x                        = atomCoord[atomI].x;
    sA->y                        = atomCoord[atomI].y;
    sA->z                        = atomCoord[atomI].z;
    sA->q                        = atomCoord[atomI].w;

    // lab dipole

    sA->labFrameDipole[0]         = labFrameDipoleJ[atomI*3];
    sA->labFrameDipole[1]         = labFrameDipoleJ[atomI*3+1];
    sA->labFrameDipole[2]         = labFrameDipoleJ[atomI*3+2];

    // lab quadrupole

    sA->labFrameQuadrupole[0]    = labQuadrupole[atomI*9];
    sA->labFrameQuadrupole[1]    = labQuadrupole[atomI*9+1];
    sA->labFrameQuadrupole[2]    = labQuadrupole[atomI*9+2];
    sA->labFrameQuadrupole[3]    = labQuadrupole[atomI*9+3];
    sA->labFrameQuadrupole[4]    = labQuadrupole[atomI*9+4];
    sA->labFrameQuadrupole[5]    = labQuadrupole[atomI*9+5];
    sA->labFrameQuadrupole[6]    = labQuadrupole[atomI*9+6];
    sA->labFrameQuadrupole[7]    = labQuadrupole[atomI*9+7];
    sA->labFrameQuadrupole[8]    = labQuadrupole[atomI*9+8];

    // induced dipole

    sA->inducedDipole[0]          = inducedDipole[atomI*3];
    sA->inducedDipole[1]          = inducedDipole[atomI*3+1];
    sA->inducedDipole[2]          = inducedDipole[atomI*3+2];

    // induced dipole polar

    sA->inducedDipoleP[0]         = inducedDipolePolar[atomI*3];
    sA->inducedDipoleP[1]         = inducedDipolePolar[atomI*3+1];
    sA->inducedDipoleP[2]         = inducedDipolePolar[atomI*3+2];

    sA->damp                     = dampingFactorAndThole[atomI].x;
    sA->thole                    = dampingFactorAndThole[atomI].y;

}

// Include versions of the kernels for N^2 calculations.

#undef USE_OUTPUT_BUFFER_PER_WARP
#define METHOD_NAME(a, b) a##N2##b
#include "kCalculateAmoebaCudaElectrostatic.h"
#define USE_OUTPUT_BUFFER_PER_WARP
#undef METHOD_NAME
#define METHOD_NAME(a, b) a##N2ByWarp##b
#include "kCalculateAmoebaCudaElectrostatic.h"

// reduce psWorkArray_3_1 -> force
// reduce psWorkArray_3_2 -> torque

static void kReduceForceTorque(amoebaGpuContext amoebaGpu )
{
    kReduceFields_kernel<<<amoebaGpu->nonbondBlocks, amoebaGpu->fieldReduceThreadsPerBlock>>>(
                               amoebaGpu->paddedNumberOfAtoms*3, amoebaGpu->outputBuffers,
                               amoebaGpu->psWorkArray_3_1->_pDevStream[0], amoebaGpu->psForce->_pDevStream[0] );
    LAUNCHERROR("kReduceElectrostaticForce");
    kReduceFields_kernel<<<amoebaGpu->nonbondBlocks, amoebaGpu->fieldReduceThreadsPerBlock>>>(
                               amoebaGpu->paddedNumberOfAtoms*3, amoebaGpu->outputBuffers,
                               amoebaGpu->psWorkArray_3_2->_pDevStream[0], amoebaGpu->psTorque->_pDevStream[0] );
    LAUNCHERROR("kReduceElectrostaticTorque");
}

#ifdef AMOEBA_DEBUG
static void printElectrostaticBuffer( amoebaGpuContext amoebaGpu, unsigned int bufferIndex )
{
    (void) fprintf( amoebaGpu->log, "Electrostatic Buffer %u\n", bufferIndex );
    unsigned int start = bufferIndex*3*amoebaGpu->paddedNumberOfAtoms;
    unsigned int stop  = (bufferIndex+1)*3*amoebaGpu->paddedNumberOfAtoms;
    for( unsigned int ii = start; ii < stop; ii += 3 ){
        unsigned int ii3Index      = ii/3;
        unsigned int bufferIndex   = ii3Index/(amoebaGpu->paddedNumberOfAtoms);
        unsigned int particleIndex = ii3Index - bufferIndex*(amoebaGpu->paddedNumberOfAtoms);
        (void) fprintf( amoebaGpu->log, "   %6u %3u %6u [%14.6e %14.6e %14.6e] [%14.6e %14.6e %14.6e]\n", 
                            ii/3,  bufferIndex, particleIndex,
                            amoebaGpu->psWorkArray_3_1->_pSysStream[0][ii],
                            amoebaGpu->psWorkArray_3_1->_pSysStream[0][ii+1],
                            amoebaGpu->psWorkArray_3_1->_pSysStream[0][ii+2],
                            amoebaGpu->psWorkArray_3_2->_pSysStream[0][ii],
                            amoebaGpu->psWorkArray_3_2->_pSysStream[0][ii+1],
                            amoebaGpu->psWorkArray_3_2->_pSysStream[0][ii+2] );
    } 

/*
    start = 0;
    stop  = -146016;
    float maxV = -1.0e+99;
    for( unsigned int ii = start; ii < stop; ii += 3 ){
        if(  amoebaGpu->psWorkArray_3_1->_pSysStream[0][ii] > maxV ){ 
            unsigned int ii3Index      = ii/3;
            unsigned int bufferIndex   = ii3Index/(amoebaGpu->paddedNumberOfAtoms);
            unsigned int particleIndex = ii3Index - bufferIndex*(amoebaGpu->paddedNumberOfAtoms);
            (void) fprintf( amoebaGpu->log, "MaxQ %6u %3u %6u %14.6e\n", 
                            ii/3,  bufferIndex, particleIndex,
                            amoebaGpu->psWorkArray_3_1->_pSysStream[0][ii] );
            maxV = amoebaGpu->psWorkArray_3_1->_pSysStream[0][ii];
        } 
    } 
*/
}

static void printElectrostaticAtomBuffers( amoebaGpuContext amoebaGpu, unsigned int targetAtom )
{
    (void) fprintf( amoebaGpu->log, "Electrostatic atom %u\n", targetAtom );
    for( unsigned int ii = 0; ii < amoebaGpu->outputBuffers; ii++ ){
        unsigned int particleIndex = 3*(targetAtom + ii*amoebaGpu->paddedNumberOfAtoms);
        (void) fprintf( amoebaGpu->log, " %2u %6u [%14.6e %14.6e %14.6e] [%14.6e %14.6e %14.6e]\n", 
                        ii, particleIndex,
                        amoebaGpu->psWorkArray_3_1->_pSysStream[0][particleIndex],
                        amoebaGpu->psWorkArray_3_1->_pSysStream[0][particleIndex+1],
                        amoebaGpu->psWorkArray_3_1->_pSysStream[0][particleIndex+2],
                        amoebaGpu->psWorkArray_3_2->_pSysStream[0][particleIndex],
                        amoebaGpu->psWorkArray_3_2->_pSysStream[0][particleIndex+1],
                        amoebaGpu->psWorkArray_3_2->_pSysStream[0][particleIndex+2] );
    } 
}
#endif

/**---------------------------------------------------------------------------------------

   Compute Amoeba electrostatic force & torque

   @param amoebaGpu        amoebaGpu context
   @param gpu              OpenMM gpu Cuda context

   --------------------------------------------------------------------------------------- */

void cudaComputeAmoebaElectrostatic( amoebaGpuContext amoebaGpu )
{
  
   // ---------------------------------------------------------------------------------------

    static unsigned int threadsPerBlock = 0;

#ifdef AMOEBA_DEBUG
    static const char* methodName = "cudaComputeAmoebaElectrostatic";
    static int timestep = 0;
    std::vector<int> fileId;
    timestep++;
    fileId.resize( 2 );
    fileId[0] = timestep;
    fileId[1] = 1;
#endif

    // ---------------------------------------------------------------------------------------

    gpuContext gpu = amoebaGpu->gpuContext;

    // apparently debug array can take up nontrivial no. registers

#ifdef AMOEBA_DEBUG
    if( amoebaGpu->log ){
        (void) fprintf( amoebaGpu->log, "%s %d maxCovalentDegreeSz=%d"
                        " gamma=%.3e scalingDistanceCutoff=%.3f ZZZ\n",
                        methodName, gpu->natoms,
                        amoebaGpu->maxCovalentDegreeSz, amoebaGpu->pGamma,
                        amoebaGpu->scalingDistanceCutoff );
    }   
   int paddedNumberOfAtoms                    = amoebaGpu->gpuContext->sim.paddedNumberOfAtoms;
    CUDAStream<float4>* debugArray            = new CUDAStream<float4>(paddedNumberOfAtoms*paddedNumberOfAtoms, 1, "DebugArray");
    memset( debugArray->_pSysStream[0],      0, sizeof( float )*4*paddedNumberOfAtoms*paddedNumberOfAtoms);
    debugArray->Upload();
    unsigned int targetAtom                   = 0;
#endif

    // on first pass, set threads/block

    if( threadsPerBlock == 0 ){
        unsigned int maxThreads;
        if (gpu->sm_version >= SM_20)
            maxThreads = 256;
        else if (gpu->sm_version >= SM_12)
            maxThreads = 128;
        else
            maxThreads = 64;
        threadsPerBlock = std::min(getThreadsPerBlock(amoebaGpu, sizeof(ElectrostaticParticle)), maxThreads);
    }

    kClearFields_3( amoebaGpu, 2 );

    if (gpu->bOutputBufferPerWarp){

        (void) fprintf( amoebaGpu->log, "kCalculateAmoebaCudaElectrostaticN2Forces warp:  numBlocks=%u numThreads=%u bufferPerWarp=%u atm=%u shrd=%u Ebuf=%u ixnCt=%u workUnits=%u\n",
                        amoebaGpu->nonbondBlocks, threadsPerBlock, amoebaGpu->bOutputBufferPerWarp,
                        sizeof(ElectrostaticParticle), sizeof(ElectrostaticParticle)*threadsPerBlock, amoebaGpu->energyOutputBuffers, (*gpu->psInteractionCount)[0], gpu->sim.workUnits );
        (void) fflush( amoebaGpu->log );
        kCalculateAmoebaCudaElectrostaticN2ByWarpForces_kernel<<<amoebaGpu->nonbondBlocks, threadsPerBlock, sizeof(ElectrostaticParticle)*threadsPerBlock>>>(
                                                                           amoebaGpu->psWorkUnit->_pDevStream[0],
                                                                           gpu->psPosq4->_pDevStream[0],
                                                                           amoebaGpu->psLabFrameDipole->_pDevStream[0],
                                                                           amoebaGpu->psLabFrameQuadrupole->_pDevStream[0],
                                                                           amoebaGpu->psInducedDipole->_pDevStream[0],
                                                                           amoebaGpu->psInducedDipolePolar->_pDevStream[0],
                                                                           amoebaGpu->psWorkArray_3_1->_pDevStream[0],
#ifdef AMOEBA_DEBUG
                                                                           amoebaGpu->psWorkArray_3_2->_pDevStream[0],
                                                                           debugArray->_pDevStream[0], targetAtom );
#else
                                                                           amoebaGpu->psWorkArray_3_2->_pDevStream[0] );
#endif

    } else {

#ifdef AMOEBA_DEBUG
        (void) fprintf( amoebaGpu->log, "kCalculateAmoebaCudaElectrostaticN2Forces no warp:  numBlocks=%u numThreads=%u bufferPerWarp=%u atm=%u shrd=%u Ebuf=%u ixnCt=%u workUnits=%u\n",
                        amoebaGpu->nonbondBlocks, threadsPerBlock, amoebaGpu->bOutputBufferPerWarp,
                        sizeof(ElectrostaticParticle), sizeof(ElectrostaticParticle)*threadsPerBlock, amoebaGpu->energyOutputBuffers, (*gpu->psInteractionCount)[0], gpu->sim.workUnits );
        (void) fflush( amoebaGpu->log );
#endif

        kCalculateAmoebaCudaElectrostaticN2Forces_kernel<<<amoebaGpu->nonbondBlocks, threadsPerBlock, sizeof(ElectrostaticParticle)*threadsPerBlock>>>(
                                                                           amoebaGpu->psWorkUnit->_pDevStream[0],
                                                                           gpu->psPosq4->_pDevStream[0],
                                                                           amoebaGpu->psLabFrameDipole->_pDevStream[0],
                                                                           amoebaGpu->psLabFrameQuadrupole->_pDevStream[0],
                                                                           amoebaGpu->psInducedDipole->_pDevStream[0],
                                                                           amoebaGpu->psInducedDipolePolar->_pDevStream[0],
                                                                           amoebaGpu->psWorkArray_3_1->_pDevStream[0],
#ifdef AMOEBA_DEBUG
                                                                           amoebaGpu->psWorkArray_3_2->_pDevStream[0],
                                                                           debugArray->_pDevStream[0], targetAtom );
#else
                                                                           amoebaGpu->psWorkArray_3_2->_pDevStream[0] );
#endif
    }
    LAUNCHERROR("kCalculateAmoebaCudaElectrostaticN2Forces");

#ifdef AMOEBA_DEBUG
    if( 0 && amoebaGpu->log ){

        amoebaGpu->psWorkArray_3_1->Download();
        amoebaGpu->psWorkArray_3_2->Download();

        printElectrostaticAtomBuffers( amoebaGpu, (targetAtom + 0) );
        //printElectrostaticAtomBuffers( amoebaGpu, (targetAtom + 1231) );
        printElectrostaticBuffer( amoebaGpu, 0 );
        //printElectrostaticBuffer( amoebaGpu, 38 );
    }
#endif

    kReduceForceTorque( amoebaGpu );

#ifdef AMOEBA_DEBUG
    if( amoebaGpu->log ){

        amoebaGpu->psForce->Download();
        amoebaGpu->psTorque->Download();
        debugArray->Download();

        (void) fprintf( amoebaGpu->log, "Finished Electrostatic kernel execution\n" ); (void) fflush( amoebaGpu->log );

        int maxPrint        = 1400;
        for( int ii = 0; ii < gpu->natoms; ii++ ){
           (void) fprintf( amoebaGpu->log, "%5d ", ii); 

            int indexOffset     = ii*3;
    
           // force

           (void) fprintf( amoebaGpu->log,"ElectrostaticF [%16.9e %16.9e %16.9e] ",
                           amoebaGpu->psForce->_pSysStream[0][indexOffset],
                           amoebaGpu->psForce->_pSysStream[0][indexOffset+1],
                           amoebaGpu->psForce->_pSysStream[0][indexOffset+2] );
    
           // torque

           (void) fprintf( amoebaGpu->log,"ElectrostaticT [%16.9e %16.9e %16.9e] ",
                           amoebaGpu->psTorque->_pSysStream[0][indexOffset],
                           amoebaGpu->psTorque->_pSysStream[0][indexOffset+1],
                           amoebaGpu->psTorque->_pSysStream[0][indexOffset+2] );

           // coords

#if 0
            (void) fprintf( amoebaGpu->log,"x[%16.9e %16.9e %16.9e] ",
                            gpu->psPosq4->_pSysStream[0][ii].x,
                            gpu->psPosq4->_pSysStream[0][ii].y,
                            gpu->psPosq4->_pSysStream[0][ii].z);


           for( int jj = 0; jj < gpu->natoms && jj < 5; jj++ ){
               int debugIndex = jj*gpu->natoms + ii;
               float xx       =  gpu->psPosq4->_pSysStream[0][jj].x -  gpu->psPosq4->_pSysStream[0][ii].x;
               float yy       =  gpu->psPosq4->_pSysStream[0][jj].y -  gpu->psPosq4->_pSysStream[0][ii].y;
               float zz       =  gpu->psPosq4->_pSysStream[0][jj].z -  gpu->psPosq4->_pSysStream[0][ii].z;
               (void) fprintf( amoebaGpu->log,"\n%4d %4d delta [%16.9e %16.9e %16.9e] [%16.9e %16.9e %16.9e] ",
                               ii, jj, xx, yy, zz,
                               debugArray->_pSysStream[0][debugIndex].x, debugArray->_pSysStream[0][debugIndex].y, debugArray->_pSysStream[0][debugIndex].z );

           }
#endif
           (void) fprintf( amoebaGpu->log,"\n" );
           if( ii == maxPrint && (gpu->natoms - maxPrint) > ii ){
                ii = gpu->natoms - maxPrint;
           }
        }
        if( 1 ){
            (void) fprintf( amoebaGpu->log,"DebugElec\n" );
            int paddedNumberOfAtoms = amoebaGpu->gpuContext->sim.paddedNumberOfAtoms;
            for( int jj = 0; jj < gpu->natoms; jj++ ){
                int debugIndex = jj;
                for( int kk = 0; kk < 5; kk++ ){
                    (void) fprintf( amoebaGpu->log,"%5d %5d [%16.9e %16.9e %16.9e %16.9e] E11\n", targetAtom, jj,
                                    debugArray->_pSysStream[0][debugIndex].x, debugArray->_pSysStream[0][debugIndex].y,
                                    debugArray->_pSysStream[0][debugIndex].z, debugArray->_pSysStream[0][debugIndex].w );
                    debugIndex += paddedNumberOfAtoms;
                }
                (void) fprintf( amoebaGpu->log,"\n" );
            }
        }
        (void) fflush( amoebaGpu->log );

        if( 0 ){
            (void) fprintf( amoebaGpu->log, "%s Tiled F & T\n", methodName ); fflush( amoebaGpu->log );
            int maxPrint = 12;
            for( int ii = 0; ii < gpu->natoms; ii++ ){
    
                // print cpu & gpu reductions
    
                int offset  = 3*ii;
    
                (void) fprintf( amoebaGpu->log,"%6d F[%16.7e %16.7e %16.7e] T[%16.7e %16.7e %16.7e]\n", ii,
                                amoebaGpu->psForce->_pSysStream[0][offset],
                                amoebaGpu->psForce->_pSysStream[0][offset+1],
                                amoebaGpu->psForce->_pSysStream[0][offset+2],
                                amoebaGpu->psTorque->_pSysStream[0][offset],
                                amoebaGpu->psTorque->_pSysStream[0][offset+1],
                                amoebaGpu->psTorque->_pSysStream[0][offset+2] );
                if( (ii == maxPrint) && (ii < (gpu->natoms - maxPrint)) )ii = gpu->natoms - maxPrint; 
            }   
        }   

        if( 1 ){
            std::vector<int> fileId;
            //fileId.push_back( 0 );
            VectorOfDoubleVectors outputVector;
            cudaLoadCudaFloat4Array( gpu->natoms, 3, gpu->psPosq4,            outputVector );
            cudaLoadCudaFloatArray( gpu->natoms,  3, amoebaGpu->psForce,      outputVector );
            cudaLoadCudaFloatArray( gpu->natoms,  3, amoebaGpu->psTorque,     outputVector);
            cudaWriteVectorOfDoubleVectorsToFile( "CudaForceTorque", fileId, outputVector );
         }

    }   
    delete debugArray;

#endif

   // ---------------------------------------------------------------------------------------
}
