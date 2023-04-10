provider "aws" {
  region = "us-east-1"
}
resource "aws_vpc" "Myvpc" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "elasticsearch-vpc"
  }
}
data "aws_availability_zones" "available" {
  state = "available"
}

# creating  subnet
resource "aws_subnet" "public" {
  count = 2

  cidr_block = "10.0.${count.index}.0/24"
  vpc_id     = aws_vpc.Myvpc.id
  availability_zone = data.aws_availability_zones.available.names[count.index % length(data.aws_availability_zones.available.names)]

  tags = {
    Name = "public-${count.index}"
  }
}

# Create Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.Myvpc.id

  tags = {
    Name = "IGW"
  }
}

# Create Web layber route table
resource "aws_route_table" "web-rt" {
  vpc_id = aws_vpc.Myvpc.id


  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "WebRT"
  }
}
resource "aws_route_table_association" "a" {
  count=2
  subnet_id     = "${element(aws_subnet.public.*.id, count.index)}"
  route_table_id = aws_route_table.web-rt.id
}

#create  security group for ELB
resource "aws_security_group" "elb" {
  name_prefix = "elasticsearch-elb"
  vpc_id      = aws_vpc.Myvpc.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
   egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

}
resource "aws_alb" "Loadbalancer" {
  name               = "LoadBalancer"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.elb.id]
  subnets            = aws_subnet.public.*.id
}
resource "aws_iam_policy" "ecs_logging" {
  name = "ecs-logging"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}


resource "aws_elasticsearch_domain" "esdomain" {
  domain_name           = "esdomain"
  elasticsearch_version = "7.4"
  cluster_config {
    instance_type = "t3.small.elasticsearch"
    instance_count = 2
    zone_awareness_enabled = true
    
  }
  ebs_options {
    ebs_enabled = true
    volume_size = 10
  }
  vpc_options {
    subnet_ids = aws_subnet.public.*.id
    security_group_ids = [aws_security_group.elb.id]
  }
 
}

resource "aws_iam_role" "ecs_task" {
  name = "ecs-task"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_task" {
  policy_arn = aws_iam_policy.ecs_logging.arn
  role       = aws_iam_role.ecs_task.name
}

resource "aws_ecs_task_definition" "Myecstask" {
  family                = "Myecstask"
  network_mode          = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                   = "256"
  memory                = "512"

  execution_role_arn    = aws_iam_role.ecs_task.arn
  task_role_arn         = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([
    {
      name      = "nginx"
      image     = "nginx"
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group" = "/ecs/ecslogs"
          "awslogs-region" = "us-east-1"
          "awslogs-stream-prefix" = "nginx"
        }
      }
    }
  ])
}

resource "aws_ecs_cluster" "EcsCluster" {
  name = "MyecsCluster"
}

resource "aws_ecs_service" "EcsService" {
  name            = "EcsService"
  cluster         = aws_ecs_cluster.EcsCluster.name
  task_definition = aws_ecs_task_definition.Myecstask.arn

  load_balancer {
    target_group_arn = aws_lb_target_group.elbtar.arn
    container_name  = "nginx"
    container_port   = 80
  }

  desired_count = 2
  launch_type   = "FARGATE"

  network_configuration {
    security_groups = [aws_security_group.elb.id]
    subnets         = aws_subnet.public.*.id
    assign_public_ip= true
  }
  depends_on = [
    aws_ecs_task_definition.Myecstask
  ]
}

resource "aws_lb_target_group" "elbtar" {
name_prefix = "elbtar"
port = 80
protocol = "HTTP"
vpc_id = aws_vpc.Myvpc.id
target_type = "ip"
depends_on = [aws_alb.Loadbalancer]
}

resource "aws_lb_listener" "listener" {
  load_balancer_arn = "${aws_alb.Loadbalancer.arn}" # Referencing our load balancer
  port              = "80"
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = "${aws_lb_target_group.elbtar.arn}" # Referencing our tagrte group
  }
}

resource "aws_cloudwatch_log_group" "web" {
name = "/ecs/ecslogs"
retention_in_days = 30
}

resource "aws_cloudwatch_log_subscription_filter" "web" {
name = "web"
log_group_name = aws_cloudwatch_log_group.web.name
filter_pattern = ""
destination_arn = aws_elasticsearch_domain.esdomain.arn
}