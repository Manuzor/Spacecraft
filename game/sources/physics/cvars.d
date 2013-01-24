module physics.cvars;

struct CVars {
	double p_drawCollisionGeometry = 0.0; //if the collision geometry should be drawn or not
  double p_drawCollisionInfo = 0.0; //if collision information should be drawn or not
  double p_fixedTimestep = 0.0; //if > 0 used a timestep for physics simulation
  double p_gravity = 1.0; //if > 0 gravity is enabled
  double p_iterations = 3.0; //how many iterations of solving should be done per frame
  double p_correctionVelocity = 0.99; //factor for getting rid of impercise floating point computation issues
  double p_correctionAngular = 0.9; //factor for getting rid of impercise floating point computation issues
  double p_debugNum = 0.0; //which debug output to draw
  double p_collisionResponse = 1.0; //which collision response to use
  double p_consumeRest = 1.0f; //if the remaining time should be simulated even if intersections would happen
}