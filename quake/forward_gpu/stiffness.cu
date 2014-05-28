/* -*- C -*- */

/* @copyright_notice_start
 *
 * This file is part of the CMU Hercules ground motion simulator developed
 * by the CMU Quake project.
 *
 * Copyright (C) Carnegie Mellon University. All rights reserved.
 *
 * This program is covered by the terms described in the 'LICENSE.txt' file
 * included with this software package.
 *
 * This program comes WITHOUT ANY WARRANTY; without even the implied warranty
 * of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * 'LICENSE.txt' file for more details.
 *
 *  @copyright_notice_end
 */

#include <inttypes.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "psolve.h"
#include "nonlinear.h" //NEEDS TO BE HERE FOR NONLINEAR TO RUN
#include "stiffness.h"
#include "quake_util.h"
#include "kernel.h"
#include "util.h"
#include "timers.h"

#include <cuda.h>
#include <cuda_runtime.h>


/* -------------------------------------------------------------------------- */
/*                             Global Variables                               */
/* -------------------------------------------------------------------------- */

static int32_t    myLinearElementsCount;
static int32_t   *myLinearElementsMapper;
static int32_t   *myLinearElementsMapperDevice;

static int calcForceBlockSize;


/* -------------------------------------------------------------------------- */
/*          Initialization of parameters for nonlinear compatibility          */
/* -------------------------------------------------------------------------- */

/**
 * Counts the number of nonlinear elements in my local mesh
 */
void linear_elements_count(int32_t myID, mesh_t *myMesh) {

    int32_t eindex;
    int32_t count = 0;

    for (eindex = 0; eindex < myMesh->lenum; eindex++) {

        if ( isThisElementNonLinear(myMesh, eindex) == NO ) {
            count++;
        }
    }

    if ( count > myMesh-> lenum ) {
        fprintf(stderr,"Thread %d: linear_elements_count: "
                "more elements than expected\n", myID);
        MPI_Abort(MPI_COMM_WORLD, ERROR);
        exit(1);
    }

    myLinearElementsCount = count;

    return;
}


/**
 * Re-counts and stores the nonlinear element indices to a static local array
 * that will serve as mapping tool to the local mesh elements table.
 */
void linear_elements_mapping(int32_t myID, mesh_t *myMesh) {

    int32_t eindex;
    int32_t count = 0;

    XMALLOC_VAR_N(myLinearElementsMapper, int32_t, myLinearElementsCount);

    for (eindex = 0; eindex < myMesh->lenum; eindex++) {

        if ( isThisElementNonLinear(myMesh, eindex) == NO ) {
            myLinearElementsMapper[count] = eindex;
            count++;
        }
    }

    if ( count != myLinearElementsCount ) {
        fprintf(stderr,"Thread %d: linear_elements_mapping: "
                "more elements than the count\n", myID);
        MPI_Abort(MPI_COMM_WORLD, ERROR);
        exit(1);
    }

    return;
}


void stiffness_init(int32_t myID, mesh_t *myMesh, mysolver_t* mySolver)
{
    linear_elements_count(myID, myMesh);
    linear_elements_mapping(myID, myMesh);
    
    /* Allocate device memory */
    if (cudaMalloc((void**)&myLinearElementsMapperDevice, 
		   myLinearElementsCount * sizeof(int32_t)) != cudaSuccess) {
        fprintf(stderr, "Thread %d: Failed to allocate mapper memory\n", myID);
        MPI_Abort(MPI_COMM_WORLD, ERROR);
        exit(1);
    }

    /* Copy linear element mapper to device */
    if (cudaMemcpy(myLinearElementsMapperDevice, myLinearElementsMapper, 
		   myLinearElementsCount * sizeof(int32_t),  
		   cudaMemcpyHostToDevice) != cudaSuccess) {
        fprintf(stderr, "Thread %d: Failed to copy mapper to device - %s\n", 
		myID, cudaGetErrorString(cudaGetLastError()));
        MPI_Abort(MPI_COMM_WORLD, ERROR);
        exit(1);
    }
    mySolver->gpu_spec->numbytespci += myLinearElementsCount * sizeof(int32_t);

    /* Dynamically calculate optimum block size for each kernel */
    calcForceBlockSize = gpu_get_blocksize(mySolver->gpu_spec,
    					   (char *)kernelStiffnessCalcLocal, 
					   0);

    return;
}


void stiffness_delete(int32_t myID) {
    /* Free stiffness module memory */
    free(myLinearElementsMapper);

    /* Free device memory */
    cudaFree(myLinearElementsMapperDevice);

    return;
}


/* -------------------------------------------------------------------------- */
/*                       Stiffness Contribution Methods                       */
/* -------------------------------------------------------------------------- */


/**
 * Compute and add the force due to the element stiffness matrices.
 *
 * \param myMesh   Pointer to the solver mesh structure.
 * \param mySolver Pointer to the solver main data structures.
 * \param theK1    First stiffness matrix (K1).
 * \param theK2    Second stiffness matrix (K2).
 */
void compute_addforce_conventional( mesh_t* myMesh, mysolver_t* mySolver, 
				    fmatrix_t (*theK1)[8], fmatrix_t (*theK2)[8] )
{
    fvector_t localForce[8];
    int       i, j;
    int32_t   eindex;
    int32_t   lin_eindex;

    /* loop on the number of elements */
    for (lin_eindex = 0; lin_eindex < myLinearElementsCount; lin_eindex++) {

        elem_t* elemp;
        e_t*    ep;

        eindex = myLinearElementsMapper[lin_eindex];
        elemp  = &myMesh->elemTable[eindex];
        ep     = &mySolver->eTable[eindex];

        /* step 1: calculate the force due to the element stiffness */
        memset( localForce, 0, 8 * sizeof(fvector_t) );

        /* contribution by node j to node i */
        for (i = 0; i < 8; i++)
        {
            fvector_t* toForce = &localForce[i];

            for (j = 0; j < 8; j++)
            {
                int32_t    nodeJ  = elemp->lnid[j];
                fvector_t* myDisp = mySolver->tm1 + nodeJ;

                /*
		 * contributions by the stiffnes/damping matrix
		 * contribution by ( - deltaT_square * Ke * Ut )
		 * But if myDisp is zero avoids multiplications
		 */
                if ( vector_is_all_zero( myDisp ) != 0 ) {
                    MultAddMatVec( &theK1[i][j], myDisp, -ep->c1, toForce );
                    MultAddMatVec( &theK2[i][j], myDisp, -ep->c2, toForce );
                }
            }
        }

        /* step 2: sum up my contribution to my vertex nodes */
        for (i = 0; i < 8; i++) {
            int32_t    lnid       = elemp->lnid[i];
            fvector_t* nodalForce = mySolver->force + lnid;

            nodalForce->f[0] += localForce[i].f[0];
            nodalForce->f[1] += localForce[i].f[1];
            nodalForce->f[2] += localForce[i].f[2];
        }
    } /* for all the elements */
}


/**
 * Compute and add the force due to the element stiffness matrices with the effective method.
 */
void compute_addforce_effective_cpu( mesh_t* myMesh, mysolver_t* mySolver )
{
    /* \TODO use mu_and_lamda to compute first,second and third coefficients */

    fvector_t localForce[8];
    fvector_t curDisp[8];
    int       i;
    int32_t   eindex;
    int32_t   lin_eindex;

    /* loop on the number of elements */
    for (lin_eindex = 0; lin_eindex < myLinearElementsCount; lin_eindex++) {

        elem_t* elemp;
        e_t*    ep;

        eindex = myLinearElementsMapper[lin_eindex];
        elemp  = &myMesh->elemTable[eindex];
        ep     = &mySolver->eTable[eindex];

        memset( localForce, 0, 8 * sizeof(fvector_t) );

        for (i = 0; i < 8; i++) {
            int32_t    lnid = elemp->lnid[i];
            fvector_t* tm1Disp = mySolver->tm1 + lnid;
//	    fvector_t* tm2Disp = mySolver->tm2 + lnid;

            curDisp[i].f[0] = tm1Disp->f[0];
            curDisp[i].f[1] = tm1Disp->f[1];
            curDisp[i].f[2] = tm1Disp->f[2];

        }

        /* Coefficients for new stiffness matrix calculation */
        if (vector_is_zero( curDisp ) != 0) {

            double first_coeff  = -0.5625 * (ep->c2 + 2 * ep->c1);
            double second_coeff = -0.5625 * (ep->c2);
            double third_coeff  = -0.5625 * (ep->c1);

            double atu[24];
            double firstVec[24];

            aTransposeU( curDisp, atu );
            firstVector( atu, firstVec, first_coeff, second_coeff, third_coeff );
            au( localForce, firstVec );
        }

        for (i = 0; i < 8; i++) {
            int32_t lnid          = elemp->lnid[i];;
            fvector_t* nodalForce = mySolver->force + lnid;

            nodalForce->f[0] += localForce[i].f[0];
            nodalForce->f[1] += localForce[i].f[1];
            nodalForce->f[2] += localForce[i].f[2];
        }
    } /* for all the elements */
}


/**
 * Compute and add the force due to the element stiffness matrices with 
   the effective method.
 */
void compute_addforce_effective_gpu( int32_t myID, 
				     mesh_t* myMesh, 
				     mysolver_t* mySolver )
{
    /* Copy working data to device */
    cudaMemcpy(mySolver->gpuData->forceDevice, mySolver->force, 
	       myMesh->nharbored * sizeof(fvector_t), cudaMemcpyHostToDevice);
    mySolver->gpu_spec->numbytespci += myMesh->nharbored * sizeof(fvector_t);

    /* Note that this executes for all elements. Threads for non-linear
       elements will exit immediately */
    int blocksize = calcForceBlockSize;
    int gridsize = (myMesh->lenum / blocksize) + 1;
    int sharedmem = 0;

    cudaGetLastError();
    kernelStiffnessCalcLocal<<<gridsize, blocksize, sharedmem>>>(myMesh->lenum, mySolver->gpuDataDevice, myLinearElementsCount, myLinearElementsMapperDevice);

    cudaError_t cerror = cudaGetLastError();
    if (cerror != cudaSuccess) {
      fprintf(stderr, "Thread %d: Calc stiffness local kernel - %s\n", myID, 
	      cudaGetErrorString(cerror));
      MPI_Abort(MPI_COMM_WORLD, ERROR);
      exit(1);
    }

    mySolver->gpu_spec->numflops += kernel_flops_per_thread(FLOP_STIFFNESS_KERNEL) * myMesh->lenum;

    mySolver->gpu_spec->numbytes += kernel_mem_per_thread(FLOP_STIFFNESS_KERNEL) * myMesh->lenum;

    /* Copy working data back to host */
    cudaMemcpy(mySolver->force, mySolver->gpuData->forceDevice,
    	       myMesh->nharbored * sizeof(fvector_t), cudaMemcpyDeviceToHost);
    mySolver->gpu_spec->numbytespci += myMesh->nharbored * sizeof(fvector_t);

    return;
}

