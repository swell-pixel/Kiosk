//
//  UIButton+Enabled.h
//

@interface UIButton (Enabled)
@end

@implementation UIButton (Enabled)

- (void)setEnabled:(BOOL)enabled
{
    [super setEnabled:enabled];
    
    UIColor *color = enabled ?
        [UIColor systemBlueColor] :
        [UIColor systemGrayColor];
    
    [[self layer] setBorderColor:color.CGColor];
    [self setTintColor:color];
}

- (void)setHighlighted:(BOOL)highlighted
{
    [super setHighlighted:highlighted];
    
    UIColor *color = highlighted ?
        [UIColor systemOrangeColor] :
        [UIColor systemBlueColor];
    
    [[self layer] setBorderColor:color.CGColor];
    [self setTintColor:color];
}

@end
