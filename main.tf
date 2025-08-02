terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "5.91.0"
    }
  }
}

provider "aws" {
  # Configuration options
  region = "us-east-1"
}

resource "aws_vpc" "myvpc" {
  cidr_block       = "57.0.0.0/16"
  instance_tenancy = "default"

  tags = {
    Name = "myvpc"
  }
}

resource "aws_subnet" "pubsub" {
  vpc_id     = aws_vpc.myvpc.id
  cidr_block = "57.0.70.0/24"

  tags = {
    Name = "pubsub"
  }
}

resource "aws_subnet" "pvtsub" {
  vpc_id     = aws_vpc.myvpc.id
  cidr_block = "57.0.80.0/24"

  tags = {
    Name = "pvtsub"
  }
}

resource "aws_internet_gateway" "myigw" {
  vpc_id = aws_vpc.myvpc.id

  tags = {
    Name = "myigw"
  }
}

resource "aws_route_table" "pub-rt" {
  vpc_id = aws_vpc.myvpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.myigw.id
  }

  tags = {
    Name = "pub-rt"
  }
}

resource "aws_route_table_association" "pubassociation" {
  subnet_id      = aws_subnet.pubsub.id
  route_table_id = aws_route_table.pub-rt.id
}

resource "aws_eip" "myeip" {
  domain   = "vpc"
}

resource "aws_nat_gateway" "mynat" {
  allocation_id = aws_eip.myeip.id
  subnet_id     = aws_subnet.pubsub.id

  tags = {
    Name = "mynat"
  }
}

resource "aws_route_table" "pvt-rt" {
  vpc_id = aws_vpc.myvpc.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_nat_gateway.mynat.id
  }

  tags = {
    Name = "pvt-rt"
  }
}

resource "aws_route_table_association" "pvtassociation" {
  subnet_id      = aws_subnet.pvtsub.id
  route_table_id = aws_route_table.pvt-rt.id
}

resource "aws_security_group" "pub-sg" {
  name        = "pub-sg"
  description = "Allow All TCP"
  vpc_id      = aws_vpc.myvpc.id

  tags = {
    Name = "pub-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "AllTCP" {
  security_group_id = aws_security_group.pub-sg.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 0
  ip_protocol       = "-1"
  to_port           = 65535
}

resource "aws_vpc_security_group_egress_rule" "pub-outbound" {
  security_group_id = aws_security_group.pub-sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

resource "aws_security_group" "pvt-sg" {
  name        = "pvt-sg"
  description = "Allow traffic only from Public"
  vpc_id      = aws_vpc.myvpc.id

  tags = {
    Name = "pvt-sg"
  }
}

resource "aws_vpc_security_group_ingress_rule" "AllTCP_pvtsg" {
  security_group_id = aws_security_group.pvt-sg.id
  referenced_security_group_id = aws_security_group.pub-sg.id
#   cidr_ipv4         = "57.0.70.0/24"
  from_port         = 0
  ip_protocol       = "-1"
  to_port           = 65535
}

resource "aws_vpc_security_group_egress_rule" "pvt-outbound" {
  security_group_id = aws_security_group.pvt-sg.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1" # semantically equivalent to all ports
}

resource "aws_instance" "HomePage" {
  ami                    = "ami-04b4f1a9cf54c11d0"
  instance_type          = "t2.micro"
  key_name               = "linux-key"
  vpc_security_group_ids = [aws_security_group.pub-sg.id]
  subnet_id              = aws_subnet.pubsub.id
  associate_public_ip_address = true

  depends_on = [aws_instance.LoginPage]  # Ensure LoginPage is created first

  user_data = <<-EOF
    #!/bin/bash
    sudo apt update -y
    sudo apt install -y apache2

    # Enable required Apache modules for reverse proxy
    sudo a2enmod proxy
    sudo a2enmod proxy_http
    sudo systemctl restart apache2
    sudo systemctl enable apache2

    # Define LoginPage's private IP dynamically
    LOGIN_PAGE_IP="${aws_instance.LoginPage.private_ip}"

    # Create Apache reverse proxy configuration
    echo "<VirtualHost *:80>
      ServerName home.local

      # Proxy all traffic to LoginPage's private IP
      ProxyPass /login http://$LOGIN_PAGE_IP/
      ProxyPassReverse /login http://$LOGIN_PAGE_IP/
    </VirtualHost>" | sudo tee /etc/apache2/sites-available/000-default.conf

    # Restart Apache to apply changes
    sudo systemctl restart apache2

    # Create custom home page with a link to /login
    echo '<html>
    <head><title>Home Page</title></head>
    <body>
      <h1>Welcome to Home Page</h1>
      <p><a href="/login">Go to Login Page</a></p>
    </body>
    </html>' | sudo tee /var/www/html/index.html

    # Set permissions so Apache can read the file
    sudo chown www-data:www-data /var/www/html/index.html
    sudo chmod 644 /var/www/html/index.html
  EOF

  tags = {
    Name = "HomePage"
  }
}

resource "aws_instance" "LoginPage" {
  ami                    = "ami-04b4f1a9cf54c11d0"
  instance_type          = "t2.micro"
  key_name               = "linux-key"
  vpc_security_group_ids = [aws_security_group.pvt-sg.id]
  subnet_id              = aws_subnet.pvtsub.id
  associate_public_ip_address = false  # No public IP

  user_data = <<-EOF
    #!/bin/bash
    sudo apt update -y
    sudo apt install -y apache2

    # Restart Apache to ensure it's running
    sudo systemctl restart apache2
    sudo systemctl enable apache2

    # Create custom login page
    echo '<html>
    <head><title>Login Page</title></head>
    <body>
      <h1>Welcome to Login Page</h1>
      <p>This is a private page.</p>
    </body>
    </html>' | sudo tee /var/www/html/index.html

    # Set correct permissions for Apache to read the file
    sudo chown www-data:www-data /var/www/html/index.html
    sudo chmod 644 /var/www/html/index.html
  EOF

  tags = {
    Name = "LoginPage"
  }
}
