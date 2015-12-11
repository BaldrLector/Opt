local IO = terralib.includec("stdio.h")
local adP = ad.ProblemSpec()
local P = adP.P
local W,H = opt.Dim("W",0), opt.Dim("H",1)

local X = adP:Image("X", opt.float3,W,H,0)
local A = adP:Image("A", opt.float3,W,H,1)
local G = adP:Graph("G", 0, "v0", W, H, 0, "v1", W, H, 1)
P:Stencil(2)

local C = terralib.includecstring [[
#include <math.h>
]]

--local w_fit = P:Param("w_fit", float, 0)
--local w_reg = P:Param("w_reg", float, 1)

-- TODO: this should be factored into a parameter
local w_fit = 50.0
local w_reg = 100.0

local unknownElement = P:UnknownType().metamethods.typ

local terra laplacianCost(idx : int32, self : P:ParameterType()) : unknownElement	
    var x0 = self.X(self.G.v0_x[idx], self.G.v0_y[idx])
    var x1 = self.X(self.G.v1_x[idx], self.G.v1_y[idx])
    return x0 - x1
end

local terra cost(i : int32, j : int32, gi : int32, gj : int32, self : P:ParameterType()) : float
	var v2 = self.X(i, j) - self.A(i, j)
	var e_fit = w_fit * v2 * v2	
	
	var res : float = e_fit(0) + e_fit(1) + e_fit(2)
	
	return res
end

local terra cost_graph(idx : int32, self : P:ParameterType()) : float
	var l0 = laplacianCost(idx, self)		
	var e_reg = w_reg*l0*l0
	
	var res : float = e_reg(0) + e_reg(1) + e_reg(2)
	
	return res
end

-- eval 2*JtF == \nabla(F); eval diag(2*(Jt)^2) == pre-conditioner
local terra gradient(i : int32, j : int32, gi : int32, gj : int32, self : P:ParameterType()) : unknownElement
	
	var x = self.X(i, j)
	var a = self.A(i, j)
	return w_fit*2.0f * (x - a)
end

local terra gradient_graph(idx : int32, self : P:ParameterType()) : unknownElement
    var l_n = laplacianCost(idx, self)	
	return 2.0f*w_reg*l_n
end

-- eval 2*JtF == \nabla(F); eval diag(2*(Jt)^2) == pre-conditioner
local terra evalJTF(i : int32, j : int32, gi : int32, gj : int32, self : P:ParameterType())
	
	var gradient : unknownElement = gradient(i, j, gi, gj, self)
	
	var pre : float = 1.0f
	return gradient, pre
end


local terra evalJTF_graph(idx : int32, self : P:ParameterType(), p : P:UnknownType(), r : P:UnknownType())
	
	var w0,h0 = self.G.v0_x[idx], self.G.v0_y[idx]
    var w1,h1 = self.G.v1_x[idx], self.G.v1_y[idx]
	
	--var gradient : unknownElement = gradient_graph(idx, self)
	-- is there a 2?
	var lap = 2.0*laplacianCost(idx, self)
	var c0 = ( 1.0f)*lap
	var c1 = (-1.0f)*lap
	
	var pre : float = 1.0f
	--return gradient, pre
	


	--write results
	var _residuum0 = -c0
	var _residuum1 = -c1
	r:atomicAdd(w0, h0, _residuum0)
	r:atomicAdd(w1, h1, _residuum1)
	
	var _pre0 = pre
	var _pre1 = pre
	--preconditioner:atomicAdd(w0, h0, _pre0)
	--preconditioner:atomicAdd(w1, h1, _pre1)
	
	var _p0 = _pre0*_residuum0
	var _p1 = _pre1*_residuum1
	p:atomicAdd(w0, h0, _p0)
	p:atomicAdd(w1, h1, _p1)
	
end
	
-- eval 2*JtJ (note that we keep the '2' to make it consistent with the gradient
local terra applyJTJ(i : int32, j : int32, gi : int32, gj : int32, self : P:ParameterType(), pImage : P:UnknownType()) : unknownElement 
    return w_fit*2.0f*pImage(i,j)
end

local terra applyJTJ_graph(idx : int32, self : P:ParameterType(), pImage : P:UnknownType(), Ap_X : P:UnknownType())
    var w0,h0 = self.G.v0_x[idx], self.G.v0_y[idx]
    var w1,h1 = self.G.v1_x[idx], self.G.v1_y[idx]
    
    var p0 = pImage(w0,h0)
    var p1 = pImage(w1,h1)

    -- (1*p0) + (-1*p1)
    var l_n = p0 - p1
    var e_reg = 2.0f*w_reg*l_n

	var c0 = 1.0 *  e_reg
	var c1 = -1.0f * e_reg
	

	Ap_X:atomicAdd(w0, h0, c0)
    Ap_X:atomicAdd(w1, h1, c1)

    var d = 0.0f
	d = d + opt.Dot(pImage(w0,h0), c0)
	d = d + opt.Dot(pImage(w1,h1), c1)					
	return d 

end
-- same functions, but expressed in math language
local IP = adP:Image("P",opt.float4,W,H,-1)
local x,a= X(0,0),A(0,0)
local p = IP(0,0)

local math_cost = w_fit * (x - a) ^ 2 
local math_cost_graph = w_reg*(X(G.v0) - X(G.v1))^2
math_cost,math_cost_graph = math_cost:sum(),math_cost_graph:sum()

local L = terralib.newlist 
if false then
    adP:createfunctionset("cost",{math_cost},L{ { graph = G, results = L{math_cost_graph}, scatters = L{} } })
    --adP:createfunctionset("gradient",math_grad)
    --adP:createfunctionset("evalJTF",math_grad,ad.toexp(1.0))
    --adP:createfunctionset("applyJTJ",math_jtj)
      
    --P:Function("cost", cost, "G", cost_graph)
    P:Function("gradient", gradient, "G", gradient_graph)
    P:Function("evalJTF", evalJTF, "G", evalJTF_graph)
    P:Function("applyJTJ", applyJTJ, "G", applyJTJ_graph)
    
else 
    P:Function("cost", 		cost, "G", cost_graph)
    P:Function("gradient", 	gradient, "G", gradient_graph)
    P:Function("evalJTF", 	evalJTF, "G", evalJTF_graph)
    P:Function("applyJTJ", 	applyJTJ, "G", applyJTJ_graph)
end

return P
