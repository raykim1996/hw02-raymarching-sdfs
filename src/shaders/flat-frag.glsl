#version 300 es
precision highp float;

uniform vec3 u_Eye, u_Ref, u_Up;
uniform vec2 u_Dimensions;  //stores the screen width and height
uniform float u_Time;

in vec2 fs_Pos;
out vec4 out_Col;

const int MAX_RAY_STEPS = 128;
const float FOV = 45.0;
const float EPSILON = 1e-6;

const vec3 EYE = vec3(0.0, 0.0, -10.0);
const vec3 ORIGIN = vec3(0.0, 0.0, 0.0);
const vec3 WORLD_UP = vec3(0.0, 1.0, 0.0);
const vec3 WORLD_RIGHT = vec3(1.0, 0.0, 0.0);
const vec3 WORLD_FORWARD = vec3(0.0, 0.0, 1.0);
const vec3 LIGHT_DIR = vec3(-1.0, -1.0, -2.0);
const vec3 lightPos = vec3(6.0, 10.0, -10.0);

struct Ray {
  vec3 origin;
  vec3 direction;
};

struct Intersection {
  vec3 position;
  vec3 normal;
  float distance_t;
  int material_id;
};
float dot2( in vec2 v ) { return dot(v,v); }
float dot2( in vec3 v ) { return dot(v,v); }
float ndot( in vec2 a, in vec2 b ) { return a.x*b.x - a.y*b.y; }

//Operations====================================================================
float unionSDF(float distance1, float distance2) {
  return min(distance1, distance2);
}

float instersectionSDF(float distance1, float distance2) {
  return max(distance1, distance2);
}

float subtractionSDF(float distance1, float distance2) {
  return max(-distance1, distance2);
}

float smin( float a, float b, float k )
{
    float h = clamp( 0.5+0.5*(b-a)/k, 0.0, 1.0 );
    return mix( b, a, h ) - k*h*(1.0-h);
}

float smax( float d1, float d2, float k ) {
    float h = clamp( 0.5 - 0.5*(d2+d1)/k, 0.0, 1.0 );
    return mix( d2, -d1, h ) + k*h*(1.0-h); }

float opSmoothIntersection( float d1, float d2, float k ) {
    float h = clamp( 0.5 - 0.5*(d2-d1)/k, 0.0, 1.0 );
    return mix( d2, d1, h ) + k*h*(1.0-h); 
}

vec3 rotateX(vec3 p, float a)
{
    return vec3(p.x, cos(a) * p.y + -sin(a) * p.z, sin(a) * p.y + cos(a) * p.z);   
}

vec3 rotateY(vec3 p, float a)
{
    return vec3(cos(a) * p.x + sin(a) * p.z, p.y, -sin(a) * p.x + cos(a) * p.z);   
}

vec3 rotateZ(vec3 p, float a)
{
    return vec3(cos(a) * p.x - sin(a) * p.y, sin(a) * p.x + cos(a) * p.y, p.z);   
}

vec3 bendPoint(vec3 p, float k)
{
    float c = cos(k*p.y);
    float s = sin(k*p.y);
    mat2  m = mat2(c,-s,s,c);
    vec3  q = vec3(m*p.xy,p.z);
    return q;
}

vec3 rgb(vec3 color) {
  return vec3(color.r / 255.0, color.g / 255.0, color.b / 255.0);
}

float ease_in_quadratic(float t) {
  return t * t;
}

float ease_out_quadratic(float t) {
  return 1.0 - ease_in_quadratic(1.0 - t);
}

float ease_in_out_quadratic(float t) {
  if (t < 0.5) {
    return (ease_in_quadratic(t * 2.0) / 2.0);
  } else {
    return (1.0 - ease_in_quadratic((1.0 - t) * 2.0) / 2.0);
  }
}

//===============================================================================
// Geometry SDF=================================================================
float sdfSphere(vec3 query_position, vec3 position, float radius)
{
    return length(query_position - position) - radius;
}

float sdBox( vec3 p, vec3 b )
{
  vec3 q = abs(p) - b;
  return length(max(q,0.0)) + min(max(q.x,max(q.y,q.z)),0.0);
}

float sdTorus( vec3 p, vec2 t ) // t = [big radius, slice radius]
{
  vec2 q = vec2(length(p.xz)-t.x,p.y);
  return length(q)-t.y;
}

float sdEllipsoid( vec3 p, vec3 r )
{
  float k0 = length(p/r);
  float k1 = length(p/(r*r));
  return k0*(k0-1.0)/k1;
}

float sdRoundCone( vec3 p, float r1, float r2, float h ) //r1 = bottom, r2 = top
{
  vec2 q = vec2( length(p.xz), p.y );
    
  float b = (r1-r2)/h;
  float a = sqrt(1.0-b*b);
  float k = dot(q,vec2(-b,a));
    
  if( k < 0.0 ) return length(q) - r1;
  if( k > a*h ) return length(q-vec2(0.0,h)) - r2;
        
  return dot(q, vec2(a,b) ) - r1;
}

float sdCappedCone( vec3 p, float h, float r1, float r2 )
{
  vec2 q = vec2( length(p.xz), p.y );
  vec2 k1 = vec2(r2,h);
  vec2 k2 = vec2(r2-r1,2.0*h);
  vec2 ca = vec2(q.x-min(q.x,(q.y<0.0)?r1:r2), abs(q.y)-h);
  vec2 cb = q - k1 + k2*clamp( dot(k1-q,k2)/dot2(k2), 0.0, 1.0 );
  float s = (cb.x<0.0 && ca.y<0.0) ? -1.0 : 1.0;
  return s*sqrt( min(dot2(ca),dot2(cb)) );
}

float sdCapsule( vec3 p, vec3 a, vec3 b, float r )
{
  vec3 pa = p - a, ba = b - a;
  float h = clamp( dot(pa,ba)/dot(ba,ba), 0.0, 1.0 );
  return length( pa - ba*h ) - r;
}

vec2 sdStick( vec3 p, vec3 a, vec3 b, float r1, float r2 )
{
  vec3 pa = p - a, ba = b - a;
  float h = clamp( dot(pa,ba)/dot(ba,ba), 0.0, 1.0 );
  return vec2(length( pa - ba*h ) - mix(r1, r2, h*h*(3.0 - 2.0*h)), h );
}

float sdBulbasaur(vec3 pos) {
  vec3 headPos = rotateX(pos, ease_in_out_quadratic(cos(u_Time * 0.3) * 0.5));
  vec3 center = vec3(0.0, 0.0, 0.0);
  vec3 q = pos - center;
  // Head==========================================================================================
  // float head_sphere = sdfSphere(pos, vec3(0.0, 0.5, 0.0), 1.0);
  float head_ellipsoid = sdEllipsoid(headPos - vec3(0.0, 0.5, 0.0), vec3(1.1, 0.9, 1.1));
  float head_torus = sdTorus(headPos - vec3(0.0, -0.1, -0.3), vec2(0.7, 0.4));
  // float chin_torus = sdTorus(rotateX(headPos, 0.5) - vec3(0.0, -0.1, -0.3), vec2(0.7, 0.2));
  float chin_torus = sdEllipsoid(rotateX(headPos, 0.5) - vec3(0.0, -0.1, -0.1), vec3(1.0, 0.4, 1.1));
  // return chin_torus;
  float head = smin(head_ellipsoid, head_torus, 0.5);
  head = smin(head, chin_torus, 0.3);
  vec3 earQ = headPos - center;
  vec3 earPos = rotateX(rotateZ(vec3(abs(earQ.x), earQ.y, earQ.z), 0.7), -0.3);
  float ear = sdRoundCone(earPos - vec3(-0.1, 1.3, -0.3), 0.3, 0.08, 0.5);
  // return ear;
  head = smin(head, ear, 0.2);
  float smiletip = sdEllipsoid(vec3(abs(q.x), q.y, q.z) - vec3(0.8, -0.1, -0.6), vec3(0.2, 0.2, 0.2));
  // return smiletip;
  head = smin(head, smiletip, 0.4);
  vec3 mouthPos = rotateX(headPos, 0.2) - vec3(0.0, 0.5, -0.2);
  float mouth = sdEllipsoid(mouthPos - vec3(0.0, -0.6 + abs(0.2 * q.x * q.x * q.x), -1.2 + 0.5 * q.x * q.x), vec3(0.9, 0.3, 0.7));
  float mouthtip = sdEllipsoid(rotateX(mouthPos, -0.5) - vec3(0.0, -0.8, -0.8 + 0.8 * q.x * q.x), vec3(0.1, 0.1, 0.04));
  head = smax(mouth, head, 0.05);
  head = smin(head, mouthtip, 0.3);
  //===============================================================================================
  // Body==========================================================================================
  float body_top = sdEllipsoid(rotateX(pos, 0.3) - vec3(0.0, -0.7, 0.2), vec3(1.0, 0.7, 0.8));
  float body_bottom = sdEllipsoid(rotateX(pos, -0.4) - vec3(0.0, -1.1, 1.4), vec3(1.0, 1.0, 1.3));
  float body = smin(body_top, body_bottom, 0.5);
  vec3 armPos = rotateY(rotateX(vec3(abs(q.x), q.y, q.z), -0.5), 0.5);
  // vec3 armPos2 = rotateY(rotateX(vec3(abs(q.x), q.y, q.z), -0.5), 0.8);
  float arms = sdRoundCone(armPos - vec3(0.9, -1.9, 0.1), 0.3, 0.2, 1.2);
  vec3 armPos2 = vec3(0.8, -2.5, -0.3);
  // float legPos3 = sdfSphere(pos, vec3(0.8, -2.0, 0.0), 0.4);
  vec3 leftArmCenter = vec3(0.7, -1.0, 0.5);
  vec3 rightArmCenter = vec3(-0.7, -1.0, 0.5);
  float leftarm = sdCapsule(rotateX(bendPoint(pos - leftArmCenter, 0.3) + leftArmCenter, -0.5), vec3(leftArmCenter.x, leftArmCenter.y - 1.1, leftArmCenter.z), leftArmCenter, 0.3);
  float rightarm = sdCapsule(rotateX(bendPoint(pos - rightArmCenter, -0.3) + rightArmCenter, -0.5), vec3(rightArmCenter.x, rightArmCenter.y - 1.1, rightArmCenter.z), rightArmCenter, 0.3);
  body = smin(body, leftarm, 0.2);
  body = smin(body, rightarm, 0.2);
  // body = smin(body, armPos3, 0.2);
  // return body;
  vec3 leftLegCenter = vec3(1.0, -2.0, 0.9);
  vec3 rightLegCenter = vec3(-1.0, -2.0, 0.9);
  float leftLeg = sdEllipsoid(pos - vec3(leftLegCenter.x, leftLegCenter.y, leftLegCenter.z + (0.4 - 0.1 * q.y * q.y)), vec3(0.4, 0.6, 0.7));
  float rightLeg = sdEllipsoid(pos - vec3(rightLegCenter.x, rightLegCenter.y, rightLegCenter.z + (0.4 - 0.1 * q.y * q.y)), vec3(0.4, 0.6, 0.7));
  float lFoot = sdEllipsoid(pos - vec3(1.0, -2.6, 0.5), vec3(0.3, 0.2, 0.5));
  float rFoot = sdEllipsoid(pos - vec3(-1.0, -2.6, 0.5), vec3(0.3, 0.2, 0.5));
  body = smin(body, leftLeg, 0.4);
  body = smin(body, rightLeg, 0.4);
  body = smin(body, lFoot, 0.2);
  body = smin(body, rFoot, 0.2);
  //===============================================================================================
  // Seed==========================================================================================
  float seed_torus = sdTorus(rotateX(pos, -0.8) - vec3(0.0, 0.7, 2.0), vec2(0.7, 0.7));
  float seed_cone = sdCappedCone(rotateX(pos, -0.8) - vec3(0.0, 1.8, 2.1), 0.4, 0.6, 0.1);
  // float seed_torus2 = sdTorus(rotateX(pos, -0.8) - vec3(0.0, 1.5, 2.1), vec2(0.8, 0.5));
  // return seed_cone;
  float seed = smin(seed_torus, seed_cone, 0.3);
  // seed = smax(seed_torus2, seed, 0.2);
  
  // float seed = 
  //===============================================================================================
  float total = smin(head, body, 0.2);
  return smin(total, seed, 0.1);
  // return smin(head_ellipsoid, head_torus, 0.5);
  return head;
}

float sdPlane(vec3 p, vec4 n)
{
    n = normalize(n);
    return dot(p, n.xyz) + n.w;
}

//==============================================================================
#define BULBASAUR_SDF sdBulbasaur(queryPos)
#define FLOOR_SDF sdPlane(queryPos, vec4(0.0, 1.0, 0.0, 2.5))
#define POKEBALL_SDF sdfSphere(queryPos, vec3(0.0, 20.0 * fract(u_Time * 0.1) * (1.0 - fract(u_Time * 0.1)) - 2.0, -3.0), 0.3)
float sceneSDF(vec3 queryPos) {
  // return sdfSphere(queryPos, vec3(0.0, 0.0, 0.0), 1.0);
    // return smin(sdfSphere(queryPos, vec3(0.0, 0.0, 0.0), 0.2),
    //             sdfSphere(queryPos, vec3(cos(u_Time * 0.01) * 2.0, 0.0, 0.0), abs(cos(u_Time * 0.01))), 0.2);
    // head = smin(sdfSphere(queryPos, vec3(0.0, 0.5, 0.0), 1.0),
    //             sdTorus(queryPos + vec3(0.0, 0.0, 0.3), vec2(0.6, 0.4)), 0.4);
    float t = 1e+6;
    
    float t2;
    
    if ((t2 = FLOOR_SDF) < t) {
        t = t2;
        // obj = FLOOR;
    }
    if ((t2 = BULBASAUR_SDF) < t) {
        t = t2;
        // obj = LONG_CUBE;
    }
    if ((t2 = POKEBALL_SDF) < t) {
      t = t2;
    }
    return t;

    // float bulbasaur = sdBulbasaur(queryPos);
    // float floorPlane = queryPos.y - (-2.6);
    // // return bulbasaur;
    // return min(bulbasaur, floorPlane);

}

float shadow(vec3 rayOri, vec3 rayDir) {
    float t = 0.001;
    for(int i = 0; i < MAX_RAY_STEPS; ++i) {
        float curr = sceneSDF(rayOri + t * rayDir);
        if(curr < EPSILON) {
            return 0.0;
        }
        t += curr;
    }
    return 1.0;
}

vec3 estimateNormal(vec3 p)
{
    vec2 d = vec2(0.0, EPSILON);
    float x = sceneSDF(p + d.yxx) - sceneSDF(p - d.yxx);
    float y = sceneSDF(p + d.xyx) - sceneSDF(p - d.xyx);
    float z = sceneSDF(p + d.xxy) - sceneSDF(p - d.xxy);
    return normalize(vec3(x, y, z));
}

Ray getRay(vec2 uv) {
  Ray r;
  vec3 lookVec = normalize(u_Ref - u_Eye);
  float len = length(u_Ref - u_Eye);
  vec3 rightVec = normalize(cross(lookVec, u_Up));

  float alpha = (FOV / 2.0);
  float aspectRatio = (u_Dimensions.x / u_Dimensions.y);

  vec3 V = u_Up * len * tan(alpha);
  vec3 H = rightVec * len * aspectRatio * tan(alpha);

  vec3 p = u_Ref + uv.x * H + uv.y * V;
  vec3 rayDir = normalize(p - u_Eye);

  r.origin = u_Eye;
  r.direction = rayDir;

  return r;
}

Intersection getRaymarchedIntersection(vec2 uv)
{
    Intersection intersection;    
    intersection.distance_t = -1.0;

    Ray r = getRay(uv);
    float distancet = 0.0;

    for (int step; step < MAX_RAY_STEPS; step++) {
        vec3 queryPoint = r.origin + r.direction * distancet;
        float currDist = sceneSDF(queryPoint);
        if (currDist < EPSILON) { 
            // current ray hit something
            intersection.position = queryPoint;
            intersection.distance_t = distancet;
            intersection.normal = estimateNormal(queryPoint);
            // intersection.material_id = mat_id;
            return intersection;
        }
        distancet += currDist;
    }
    return intersection;
}

vec3 getSceneColor(vec2 uv)
{
    Intersection intersection = getRaymarchedIntersection(uv);
    if (intersection.distance_t > 0.0) {
        // return vec3(1.0f);
        vec3 lightVec = normalize(lightPos - intersection.position);
        float diffuseTerm = dot(intersection.normal, normalize(lightVec));
        diffuseTerm = clamp(diffuseTerm, 0.f, 1.f);
        float ambientTerm = 0.2;
        float lightIntensity = diffuseTerm + ambientTerm;  
        float shadow = shadow(intersection.position, normalize(lightVec));
        vec3 color = rgb(vec3(146.0, 209.0, 179.0));

        return color * lightIntensity * shadow;
    }
    return rgb(vec3(136.0, 206.0, 235.0));
}

void main() {
  out_Col = vec4(0.5 * (fs_Pos + vec2(1.0)), 0.5 * (sin(u_Time * 3.14159 * 0.01) + 1.0), 1.0);

  // Check if raycast function is correct=============
  // Ray r = getRay(fs_Pos);
  // out_Col = vec4(0.5 * (r.direction + vec3(1.0, 1.0, 1.0)), 1.0);
  //====================================================
  out_Col = vec4(getSceneColor(fs_Pos), 1.0);
}